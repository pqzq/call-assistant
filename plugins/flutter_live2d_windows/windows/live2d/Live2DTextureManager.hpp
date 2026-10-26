#pragma once

#include <string>
#include <GL/glew.h>
#include <Type/CubismBasicType.hpp>
#include <Type/csmVector.hpp>

class Live2DTextureManager
{
public:
    struct TextureInfo
    {
        GLuint      id;
        int         width;
        int         height;
        std::string fileName;
    };

    Live2DTextureManager();
    ~Live2DTextureManager();

    TextureInfo* CreateTextureFromPngFile(const std::string& filePath);
    void         ReleaseTextures();
    void         ReleaseTexture(GLuint textureId);

private:
    Csm::csmVector<TextureInfo*> _textures;
};
