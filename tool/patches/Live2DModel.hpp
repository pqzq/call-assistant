#pragma once

#include <string>
#include <CubismFramework.hpp>
#include <Model/CubismUserModel.hpp>
#include <ICubismModelSetting.hpp>
#include <Type/csmVector.hpp>
#include <Type/csmMap.hpp>
#include <Math/CubismMatrix44.hpp>
#include "Live2DTextureManager.hpp"

class Live2DModel : public Csm::CubismUserModel
{
public:
    explicit Live2DModel(Live2DTextureManager* textureManager);
    virtual ~Live2DModel();

    void LoadAssets(const Csm::csmChar* modelDir, const Csm::csmChar* modelFileName);
    void Update();
    void Draw(const Csm::CubismMatrix44& matrix);

    void StartMotion(const Csm::csmChar* group, Csm::csmInt32 index, Csm::csmInt32 priority);
    void SetExpression(Csm::csmInt32 index);
    void SetParameterValue(const Csm::csmChar* parameterId, Csm::csmFloat32 value);

    /// 外部**持续驱动**的参数（嘴型等）。
    ///
    /// 与 SetParameterValue 的区别：Update() 开头会 `_model->LoadParameters()`
    /// 把所有参数重置回默认值，所以直接 Set 的值活不过一帧（嘴型永远是 0）。
    /// 这里把值缓存下来，在每帧 `_model->Update()`（参数写入顶点）之前
    /// 重新应用一次，才能真正驱动嘴型。
    void SetExternalParameter(const Csm::csmChar* parameterId, Csm::csmFloat32 value);

    /// Sets the motion playback speed multiplier (default 1.0).
    /// Physics, eye-blink and expressions are NOT affected.
    void SetMotionSpeed(Csm::csmFloat32 speed);

    // Must be called AFTER CreateRenderer()
    void SetupTextures();

    // Resize only the clipping mask FBO when the viewport changes.
    // Cheaper than CreateRenderer() because shaders are preserved.
    void ResizeMaskBuffer(int width, int height);


    bool IsLoaded() const { return _modelSetting != nullptr; }

    /// 取模型的 canvas 尺寸（模型空间）
    ///
    /// 用于按**长宽比**适配视口：canvas 尺寸决定模型的实际外框，
    /// 直接按容器宽高拉伸会把模型压扁。
    void GetCanvasSize(float& width, float& height) const;

    /// 取模型**内容**（所有 drawable 顶点的并集）在模型空间的包围盒
    ///
    /// Live2D 的 canvas 四周留白很大（角色只占中间一部分），
    /// 按 canvas 适配会让角色在竖长的盒子里显得又细又长。
    /// 用 drawable 顶点算出的才是角色**本体**的范围。
    /// 取模型**内容**（所有 drawable 顶点的并集）在模型空间的包围盒
    ///
    /// Live2D 的 canvas 四周留白很大（角色只占中间一部分），
    /// 按 canvas 适配会让角色在竖长的盒子里显得又细又长。
    /// 用 drawable 顶点算出的才是角色**本体**的范围。
    ///
    /// ⚠️ 必须在 `_model->Update()` **之后**才有意义：顶点数据是
    /// Update 写进去的，加载完那一帧还没 Update 时是空的。
    /// 所以这里返回的是 [RefreshContentBounds] 缓存下来的值。
    void GetContentBounds(
        float& minX, float& minY, float& maxX, float& maxY) const;

    /// 重新计算内容边界（每帧 Update 之后调用）
    void RefreshContentBounds();

protected:
    Csm::csmByte* CreateBuffer(const Csm::csmChar* path, Csm::csmSizeInt* size);
    void          DeleteBuffer(Csm::csmByte* buffer, const Csm::csmChar* path = "");

private:
    /// 外部持续驱动参数（嘴型等），每帧 Update() 末尾重新应用
    Csm::csmMap<Csm::csmString, Csm::csmFloat32> _externalParams;

    /// 内容边界缓存（模型空间），每帧 Update 之后刷新
    float _contentMinX = 0.0f;
    float _contentMinY = 0.0f;
    float _contentMaxX = 0.0f;
    float _contentMaxY = 0.0f;
    bool _contentBoundsValid = false;

public:

    /// 取模型**内容**（drawable 顶点）在**模型空间**的中心
    ///
    /// Live2D 的 canvas 四周有留白，角色本体并不在 canvas 中心 ——
    /// 缩放后若按 canvas 居中，角色会偏出去（贴边时只露出腿）。
    /// 配合 `CubismModelMatrix::SetCenterPosition()` 就能把内容对齐到中心。
    void GetContentCenter(float& centerX, float& centerY) const;
    void SetupModel();
    void PreloadMotionGroup(const Csm::csmChar* group);
    void ReleaseMotions();
    void ReleaseExpressions();

    Csm::ICubismModelSetting*  _modelSetting;
    std::string                _modelHomeDir;
    Csm::csmFloat32            _userTimeSeconds;
    Csm::csmFloat32            _motionSpeed = 1.0f;
    Live2DTextureManager*      _textureManager;

    Csm::csmVector<Csm::CubismIdHandle> _lipSyncIds;
    Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> _motions;
    Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> _expressions;

    const Csm::CubismId* _idParamAngleX;
    const Csm::CubismId* _idParamAngleY;
    const Csm::CubismId* _idParamAngleZ;
    const Csm::CubismId* _idParamBodyAngleX;
    const Csm::CubismId* _idParamEyeBallX;
    const Csm::CubismId* _idParamEyeBallY;
};
