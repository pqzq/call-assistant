package com.callassistant.call_assistant

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 音频解码器：把常见音频格式（mp3 / m4a / aac / ogg / wav / amr / flac 等）
 * 解码成 16kHz 单声道 16bit PCM 的 WAV。
 *
 * 输出写成 WAV 文件（而不是把 PCM 通过 MethodChannel 传回），
 * 是为了绕开 Binder 事务 1MB 限制 —— 长录音的 PCM 可能几十 MB。
 */
object AudioDecoder {

    /** 识别模型统一要求的采样率 */
    const val TARGET_SAMPLE_RATE = 16000

    /** 解码音频文件并写出 16kHz 单声道 WAV，失败返回 null */
    fun decodeToWav(srcPath: String, outFile: File): String? {
        return try {
            val pcm = decodeToPcm(srcPath) ?: return null
            if (pcm.isEmpty()) return null
            writeWav(outFile, pcm, TARGET_SAMPLE_RATE)
            outFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** 解码 + 转单声道 + 重采样，返回 [-1, 1] 的采样值 */
    private fun decodeToPcm(path: String): FloatArray? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) return null
            extractor.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = max(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val out = ArrayList<Float>(srcRate * 4)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var emptyTurns = 0

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10000)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)
                        if (inBuf != null) {
                            val size = extractor.readSampleData(inBuf, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        } else {
                            inputDone = true
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, 10000)
                when {
                    outIndex >= 0 -> {
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                        if (info.size > 0) {
                            val outBuf = codec.getOutputBuffer(outIndex)
                            if (outBuf != null) {
                                outBuf.position(info.offset)
                                outBuf.limit(info.offset + info.size)
                                val bytes = ByteArray(info.size)
                                outBuf.get(bytes)
                                var i = 0
                                while (i + 1 < bytes.size) {
                                    val v = ((bytes[i + 1].toInt() shl 8) or (bytes[i].toInt() and 0xFF)).toShort()
                                    out.add(v / 32768f)
                                    i += 2
                                }
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        emptyTurns = 0
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                    else -> {
                        emptyTurns++
                        if (inputDone && emptyTurns > 50) outputDone = true
                    }
                }
            }

            val mono = toMono(out.toFloatArray(), channels)
            return resample(mono, srcRate, TARGET_SAMPLE_RATE)
        } catch (e: Exception) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }
    /** 多声道混合成单声道 */
    private fun toMono(samples: FloatArray, channels: Int): FloatArray {
        if (channels <= 1) return samples
        val frames = samples.size / channels
        val mono = FloatArray(frames)
        for (f in 0 until frames) {
            var sum = 0f
            for (c in 0 until channels) {
                sum += samples[f * channels + c]
            }
            mono[f] = sum / channels
        }
        return mono
    }

    /** 线性插值重采样 */
    private fun resample(samples: FloatArray, srcRate: Int, dstRate: Int): FloatArray {
        if (srcRate == dstRate || samples.isEmpty()) return samples
        val ratio = srcRate.toDouble() / dstRate.toDouble()
        val dstLen = (samples.size / ratio).roundToInt()
        if (dstLen <= 0) return FloatArray(0)
        val out = FloatArray(dstLen)
        for (i in 0 until dstLen) {
            val pos = i * ratio
            val i0 = pos.toInt().coerceIn(0, samples.size - 1)
            val i1 = min(i0 + 1, samples.size - 1)
            val frac = (pos - i0).toFloat()
            out[i] = samples[i0] * (1f - frac) + samples[i1] * frac
        }
        return out
    }

    /** 写 16bit PCM 单声道 WAV */
    private fun writeWav(file: File, samples: FloatArray, sampleRate: Int) {
        file.parentFile?.mkdirs()
        val dataSize = samples.size * 2
        RandomAccessFile(file, "rw").use { raf ->
            raf.setLength(0)
            raf.writeBytes("RIFF")
            writeIntLE(raf, 36 + dataSize)
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            writeIntLE(raf, 16)
            writeShortLE(raf, 1)
            writeShortLE(raf, 1)
            writeIntLE(raf, sampleRate)
            writeIntLE(raf, sampleRate * 2)
            writeShortLE(raf, 2)
            writeShortLE(raf, 16)
            raf.writeBytes("data")
            writeIntLE(raf, dataSize)
            val buf = ByteArray(2)
            for (s in samples) {
                val v = (max(-1f, min(1f, s)) * 32767f).toInt()
                buf[0] = (v and 0xFF).toByte()
                buf[1] = ((v shr 8) and 0xFF).toByte()
                raf.write(buf)
            }
        }
    }

    private fun writeIntLE(raf: RandomAccessFile, value: Int) {
        raf.write(value and 0xFF)
        raf.write((value shr 8) and 0xFF)
        raf.write((value shr 16) and 0xFF)
        raf.write((value shr 24) and 0xFF)
    }

    private fun writeShortLE(raf: RandomAccessFile, value: Int) {
        raf.write(value and 0xFF)
        raf.write((value shr 8) and 0xFF)
    }
}