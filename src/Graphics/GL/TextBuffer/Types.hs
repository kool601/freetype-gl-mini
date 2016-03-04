{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Graphics.GL.TextBuffer.Types where

import Graphics.GL.Pal

import Data.Sequence (Seq)

import Control.Lens.Extra

import Graphics.GL.Freetype.Types

type TextSeq = Seq (Seq Char)
type ColNum = Int
type LineNum = Int
data Cursor = Cursor LineNum ColNum deriving (Eq, Show)
type Selection = (Cursor, Cursor)

data TextBuffer = TextBuffer 
  { bufSelection    :: !(Maybe Selection)
  , bufColumn       :: !Int
  , bufText         :: !TextSeq
  , bufPath         :: !(Maybe FilePath)
  , bufUndo         :: !(Maybe TextBuffer)
  } deriving Show

data TextMetrics = TextMetrics
  { txmCharIndices :: ![GLint]
  , txmCharOffsets :: ![(Cursor, V2 GLfloat)]
  , txmNumChars    :: !Int
  }

data TextRenderer = TextRenderer
  { _txrFont         :: !Font
  , _txrVAO          :: !VertexArrayObject
  , _txrIndexBuffer  :: !ArrayBuffer
  , _txrOffsetBuffer :: !ArrayBuffer
  , _txrTextBuffer   :: !TextBuffer
  , _txrTextMetrics  :: !TextMetrics
  }
makeLenses ''TextRenderer
