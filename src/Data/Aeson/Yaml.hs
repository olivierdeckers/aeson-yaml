{-|
This library exposes functions for encoding any Aeson value as YAML.
There is also support for encoding multiple values into YAML
"documents".

This library is pure Haskell, and does not depend on C FFI with
libyaml. It is also licensed under the BSD3 license.

This module is meant to be imported qualified.
-}
{-# LANGUAGE OverloadedStrings #-}

module Data.Aeson.Yaml
  ( encode
  , encodeDocuments
  , encodeQuoted
  , encodeQuotedDocuments
  ) where

import Data.Aeson hiding (encode)
import qualified Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as ByteString.Builder
import qualified Data.ByteString.Lazy as ByteString.Lazy
import qualified Data.ByteString.Short as ByteString.Short
import Data.Char (isDigit)
import qualified Data.HashMap.Strict as HashMap
import Data.List (intersperse, sortOn)
import Data.Monoid ((<>), mconcat, mempty)
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.Encoding as Text.Encoding
import qualified Data.Vector as Vector

b :: ByteString -> Builder
b = ByteString.Builder.byteString

bl :: ByteString.Lazy.ByteString -> Builder
bl = ByteString.Builder.lazyByteString

bs :: ByteString.Short.ShortByteString -> Builder
bs = ByteString.Builder.shortByteString

indent :: Int -> Builder
indent 0 = mempty
indent n = bs "  " <> (indent $! n - 1)

-- | Encode a value as YAML (lazy bytestring).
encode :: ToJSON a => a -> ByteString.Lazy.ByteString
encode v =
  ByteString.Builder.toLazyByteString $
  encodeBuilder False False 0 (toJSON v) <> bs "\n"

-- | Encode multiple values separated by '\n---\n'. To encode values of different
-- types, @import Data.Aeson(ToJSON(toJSON))@ and do
-- @encodeDocuments [toJSON x, toJSON y, toJSON z]@.
encodeDocuments :: ToJSON a => [a] -> ByteString.Lazy.ByteString
encodeDocuments vs = ByteString.Builder.toLazyByteString $ output <> bs "\n"
  where
    output =
      mconcat $
      intersperse (bs "\n---\n") $ map (encodeBuilder False False 0 . toJSON) vs

-- | Encode a value as YAML (lazy bytestring). Keys and strings are always
-- quoted.
encodeQuoted :: ToJSON a => a -> ByteString.Lazy.ByteString
encodeQuoted v =
  ByteString.Builder.toLazyByteString $
  encodeBuilder True False 0 (toJSON v) <> bs "\n"

-- | Encode multiple values separated by '\n---\n'. Keys and strings are always
-- quoted.
encodeQuotedDocuments :: ToJSON a => [a] -> ByteString.Lazy.ByteString
encodeQuotedDocuments vs =
  ByteString.Builder.toLazyByteString $ output <> bs "\n"
  where
    output =
      mconcat $
      intersperse (bs "\n---\n") $ map (encodeBuilder True False 0 . toJSON) vs

encodeBuilder :: Bool -> Bool -> Int -> Data.Aeson.Value -> Builder
encodeBuilder alwaysQuote newlineBeforeObject level value =
  case value of
    Object hm ->
      mconcat $
      (if newlineBeforeObject
         then (prefix :)
         else id) $
      intersperse prefix $ map (keyValue level) (sortOn fst $ HashMap.toList hm)
      where prefix = bs "\n" <> indent level
    Array vec ->
      if Vector.null vec
        then bs " []"
        else mconcat $
             (prefix :) $
             intersperse prefix $
             map
               (encodeBuilder alwaysQuote False (level + 1))
               (Vector.toList vec)
      where prefix = bs "\n" <> indent level <> bs "- "
    String s -> encodeText True alwaysQuote level s
    Number n -> bl (Data.Aeson.encode n)
    Bool bool -> bl (Data.Aeson.encode bool)
    Null -> bs "null"
  where
    keyValue level' (k, v) =
      mconcat
        [ encodeText False alwaysQuote level k
        , ":"
        , case v of
            Object _ -> ""
            Array _ -> ""
            _ -> " "
        , encodeBuilder alwaysQuote True (level' + 1) v
        ]

encodeText :: Bool -> Bool -> Int -> Text -> Builder
encodeText canMultiline alwaysQuote level s
  | canMultiline && "\n" `Text.isSuffixOf` s = encodeLines level (Text.lines s)
  | alwaysQuote && unquotable =
    bs "'" <> b (Text.Encoding.encodeUtf8 s) <> bs "'"
  | alwaysQuote || not unquotable = bl $ Data.Aeson.encode s
  | otherwise = b (Text.Encoding.encodeUtf8 s)
  where
    unquotable =
      s /= "" &&
      not isSpecial &&
      isSafeAscii (Text.head s) &&
      not (Text.all isNumberOrDateRelated s) && Text.all isAllowed s
    isSpecial
      | Text.length s > 5 = False
      | otherwise =
        case Text.toLower s of
          "true" -> True
          "false" -> True
          _ -> False
    isSafeAscii c =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') || c == '/' || c == '_' || c == '.' || c == '='
    isNumberOrDateRelated c = isDigit c || c == '.' || c == 'e' || c == '-'
    isAllowed c
      -- We don't include ' ' here to avoid sequences like " -" and ": "
     = isSafeAscii c || c == '-' || c == ':'

encodeLines :: Int -> [Text] -> Builder
encodeLines level ls =
  mconcat $
  (prefix :) $
  intersperse (bs "\n" <> indent level) $ map (b . Text.Encoding.encodeUtf8) ls
  where
    prefix =
      mconcat
        [ bs "|"
        , if needsIndicator
            then bs "2"
            else mempty
        , "\n"
        , indent level
        ]
    needsIndicator =
      case ls of
        (line:_) -> " " `Text.isPrefixOf` line
        _ -> False
