{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ViewPatterns #-}
module Graphics.GL.Freetype.GlyphQuad where

import Graphics.GL.Freetype.API

import Graphics.GL.Pal

import Control.Monad
import Control.Monad.Trans
import qualified Data.Map as Map
import Data.Map (Map, (!))
import Data.Foldable

data GlyphUniforms = GlyphUniforms
    { uMVP             :: UniformLocation (M44 GLfloat)
    , uTexture         :: UniformLocation GLint
    , uColor           :: UniformLocation (V3 GLfloat)
    } deriving Data

data Font = Font 
    { fntFontPtr       :: FontPtr
    , fntAtlas         :: TextureAtlas
    , fntTextureID     :: TextureID
    , fntUniforms      :: GlyphUniforms
    , fntShader        :: Program
    , fntPointSize     :: Float
    , fntGlyphsByChar  :: Map Char Glyph
    , fntVAO           :: VertexArrayObject
    , fntIndexBuffer   :: ArrayBuffer
    , fntOffsetBuffer  :: ArrayBuffer
    }

data Glyph = Glyph
  { glyIndex    :: GLint
  , glyGlyphPtr :: GlyphPtr
  , glyMetrics  :: GlyphMetrics
  }

-- Aka ASCII codes 32-126
asciiChars :: String
asciiChars = cursorChar:blockChar:[' '..'~']

blockChar :: Char
blockChar = '█'

cursorChar :: Char
cursorChar = '▏'

createFont :: String -> Float -> Program -> IO Font
createFont fontFile pointSize shader = createFontWithChars fontFile pointSize shader asciiChars

createFontWithChars :: String -> Float -> Program -> String -> IO Font
createFontWithChars fontFile pointSize shader characters = do
    -- Create an atlas to hold the characters
    atlas  <- newTextureAtlas 1024 1024 BitDepth1
    -- Create a font and associate it with the atlas
    font   <- newFontFromFile atlas pointSize fontFile
    -- Load the characters into the atlas
    missed <- loadFontGlyphs font characters
    when (missed > 0) $
      putStrLn ("Tried to load too many characters! Missed: " ++ show missed)
    
    let textureID = TextureID (atlasTextureID atlas)

    
    (characterMetrics, glyphsByChar) <- foldM (\(allCharacterMetrics, glyphsByChar) (character, i) -> do

      glyphPtr                 <- getGlyph font character
      metrics@GlyphMetrics{..} <- getGlyphMetrics glyphPtr

      let x0  = gmOffsetX
          y0  = gmOffsetY
          x1  = gmOffsetX + gmWidth
          y1  = gmOffsetY - gmHeight

          charPositions = concatMap toList
                    [ V4 x0 y1 gmS0 gmT1
                    , V4 x0 y0 gmS0 gmT0  
                    , V4 x1 y1 gmS1 gmT1  
                    , V4 x1 y0 gmS1 gmT0 ] :: [GLfloat]

          charMetricsStructureFlattened = charPositions

          glyph = Glyph { glyIndex = i, glyGlyphPtr = glyphPtr, glyMetrics = metrics }
          newAllCharacterMetrics = allCharacterMetrics ++ charMetricsStructureFlattened
          newGlyphsByChar        = Map.insert character glyph glyphsByChar
      -- print character
      -- print (charPositions)
      return (newAllCharacterMetrics, newGlyphsByChar)
      ) mempty (zip characters [0..])

    charMetricsBuffer <- bufferUniformData GL_STATIC_DRAW characterMetrics

    -- Set up our UBO globally
    let charMetricsBindingPoint = UniformBlockBindingPoint 0
    bindUniformBufferBase charMetricsBuffer charMetricsBindingPoint

    -- Bind the shader's uniform buffer declaration to the correct uniform buffer object
    bindShaderUniformBuffer shader "charactersBlock" charMetricsBindingPoint

    glyphVAO <- newVAO

    -- Reserve space for 10000 characters
    glyphIndexBuffer  <- bufferData GL_DYNAMIC_DRAW ([0..10000] :: [GLint])
    glyphOffsetBuffer <- bufferData GL_DYNAMIC_DRAW (concatMap toList (replicate 10000 (0::V2 GLfloat)))

    withVAO glyphVAO $ do
      withArrayBuffer glyphIndexBuffer $ do
        let name = "aInstanceGlyphIndex"
        attribute <- getShaderAttribute shader name
        assignIntegerAttribute shader name GL_INT 1
        vertexAttribDivisor attribute 1
      withArrayBuffer glyphOffsetBuffer $ do
        let name = "aInstanceCharacterOffset"
        attribute <- getShaderAttribute shader name
        assignFloatAttribute shader name GL_FLOAT 2
        vertexAttribDivisor attribute 1

    uniforms <- acquireUniforms shader

    return Font
        { fntFontPtr            = font
        , fntAtlas              = atlas
        , fntTextureID          = textureID
        , fntUniforms           = uniforms
        , fntShader             = shader
        , fntPointSize          = pointSize
        , fntVAO                = glyphVAO
        , fntIndexBuffer        = glyphIndexBuffer
        , fntOffsetBuffer       = glyphOffsetBuffer
        , fntGlyphsByChar       = glyphsByChar
        }


renderText :: (Foldable f, MonadIO m) 
           => Font -> f Char -> (Int, Int) -> M44 GLfloat -> m ()
renderText Font{..} string (selStart, selEnd) mvp = do
    useProgram fntShader
    glBindTexture GL_TEXTURE_2D (unTextureID fntTextureID)

    let GlyphUniforms{..} = fntUniforms

    uniformM44 uMVP     (mvp !*! scaleMatrix 0.005)
    uniformI   uTexture 0
    uniformV3  uColor   (V3 1 1 1)

    let blockGlyph  = fntGlyphsByChar ! blockChar
        cursorGlyph = fntGlyphsByChar ! cursorChar
        renderChar (charNum, lineNum, lastXOffset, maybeLastChar, indexesF, offsetsF) character = do
          -- Render newlines as spaces
          let glyph      = fntGlyphsByChar ! (if character == '\n' then ' ' else character)

          -- Find the optimal kerning between this character and the last one rendered (if any)
          kerning <- maybe (return 0) (getGlyphKerning (glyGlyphPtr glyph)) maybeLastChar

          -- Adjust the character's x offset to nestle against the previous character
          let charXOffset = lastXOffset + kerning
              nextXOffset = charXOffset + gmAdvanceX (glyMetrics glyph)
              charOffset = V2 charXOffset (-lineNum * fntPointSize)
              (indexes, offsets) 
                | charNum == selStart && charNum == selEnd =
                  let indexes' = glyIndex cursorGlyph : glyIndex glyph : indexesF :: [GLint]
                      offsets' = charOffset           : charOffset     : offsetsF :: [V2 GLfloat]
                  in (indexes', offsets')
                | charNum >= selStart && charNum < selEnd = 
                  let indexes' = glyIndex blockGlyph : glyIndex glyph : indexesF :: [GLint]
                      offsets' = charOffset          : charOffset     : offsetsF :: [V2 GLfloat]
                  in (indexes', offsets')
                | otherwise =
                  let indexes' = glyIndex glyph : indexesF :: [GLint]
                      offsets' = charOffset     : offsetsF :: [V2 GLfloat]
                  in (indexes', offsets')
          
          return $ if character == '\n'
              then (charNum + 1, lineNum + 1,           0, Nothing       , indexes, offsets)
              else (charNum + 1, lineNum    , nextXOffset, Just character, indexes, offsets)
    (_, _, _, _, indexes, offsets) <- foldlM renderChar (0, 0, 0, Nothing, [], []) string
    -- liftIO$print (reverse indexes)
    bufferSubData fntIndexBuffer  (reverse indexes)
    bufferSubData fntOffsetBuffer (concatMap toList $ reverse offsets)

    let numVertices  = 4
        numInstances = fromIntegral (length string)
    withVAO fntVAO $ 
      glDrawArraysInstanced GL_TRIANGLE_STRIP 0 numVertices numInstances
    return ()
