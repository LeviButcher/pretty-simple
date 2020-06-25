{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

{-|
Module      : Text.Pretty.Simple.Internal.OutputPrinter
Copyright   : (c) Dennis Gosnell, 2016
License     : BSD-style (see LICENSE file)
Maintainer  : cdep.illabout@gmail.com
Stability   : experimental
Portability : POSIX

-}
module Text.Pretty.Simple.Internal.OutputPrinter
  where

#if __GLASGOW_HASKELL__ < 710
-- We don't need this import for GHC 7.10 as it exports all required functions
-- from Prelude
import Control.Applicative
#endif

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad (join)
import Control.Monad.State (MonadState, evalState, modify, gets)
import Data.Bool (bool)
import Data.Char (isPrint, isSpace, ord)
import Data.List (intersperse)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Maybe (fromMaybe)
import Data.Text.Prettyprint.Doc
  (Doc, SimpleDocStream, annotate, defaultLayoutOptions, enclose, flatAlt,
    group, hcat, indent, layoutPretty, line, line', unAnnotateS, pretty)
import Data.Text.Prettyprint.Doc.Render.Terminal (AnsiStyle)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Numeric (showHex)
import System.IO (Handle, hIsTerminalDevice)
import Text.Read (readMaybe)

import Text.Pretty.Simple.Internal.Expr
  (Expr(..), CommaSeparated(CommaSeparated))
import Text.Pretty.Simple.Internal.ExprParser (expressionParse)
import Text.Pretty.Simple.Internal.Color
       (ColorOptions(..), defaultColorOptionsDarkBg,
        defaultColorOptionsLightBg)

-- $setup
-- >>> import Text.Pretty.Simple (pPrintString, pPrintStringOpt)

-- | Determines whether pretty-simple should check if the output 'Handle' is a
-- TTY device.  Normally, users only want to print in color if the output
-- 'Handle' is a TTY device.
data CheckColorTty
  = CheckColorTty
  -- ^ Check if the output 'Handle' is a TTY device.  If the output 'Handle' is
  -- a TTY device, determine whether to print in color based on
  -- 'outputOptionsColorOptions'. If not, then set 'outputOptionsColorOptions'
  -- to 'Nothing' so the output does not get colorized.
  | NoCheckColorTty
  -- ^ Don't check if the output 'Handle' is a TTY device.  Determine whether to
  -- colorize the output based solely on the value of
  -- 'outputOptionsColorOptions'.
  deriving (Eq, Generic, Show, Typeable)

-- | Control how escaped and non-printable are output for strings.
--
-- See 'outputOptionsStringStyle' for what the output looks like with each of
-- these options.
data StringOutputStyle
  = Literal
  -- ^ Output string literals by printing the source characters exactly.
  --
  -- For examples: without this option the printer will insert a newline in
  -- place of @"\n"@, with this options the printer will output @'\'@ and
  -- @'n'@. Similarly the exact escape codes used in the input string will be
  -- replicated, so @"\65"@ will be printed as @"\65"@ and not @"A"@.
  | EscapeNonPrintable
  -- ^ Replace non-printable characters with hexadecimal escape sequences.
  | DoNotEscapeNonPrintable
  -- ^ Output non-printable characters without modification.
  deriving (Eq, Generic, Show, Typeable)

-- | Data-type wrapping up all the options available when rendering the list
-- of 'Output's.
data OutputOptions = OutputOptions
  { outputOptionsIndentAmount :: Int
  -- ^ Number of spaces to use when indenting.  It should probably be either 2
  -- or 4.
  , outputOptionsColorOptions :: Maybe ColorOptions
  -- ^ If this is 'Nothing', then don't colorize the output.  If this is
  -- @'Just' colorOptions@, then use @colorOptions@ to colorize the output.
  --
  , outputOptionsStringStyle :: StringOutputStyle
  -- ^ Controls how string literals are output.
  --
  -- By default, the pPrint functions escape non-printable characters, but
  -- print all printable characters:
  --
  -- >>> pPrintString "\"A \\x42 Ä \\xC4 \\x1 \\n\""
  -- "A B Ä Ä \x1 "
  --
  -- Here, you can see that the character @A@ has been printed as-is.  @\x42@
  -- has been printed in the non-escaped version, @B@.  The non-printable
  -- character @\x1@ has been printed as @\x1@.  Newlines will be removed to
  -- make the output easier to read.
  --
  -- This corresponds to the 'StringOutputStyle' called 'EscapeNonPrintable'.
  --
  -- (Note that in the above and following examples, the characters have to be
  -- double-escaped, which makes it somewhat confusing...)
  --
  -- Another output style is 'DoNotEscapeNonPrintable'.  This is similar
  -- to 'EscapeNonPrintable', except that non-printable characters get printed
  -- out literally to the screen.
  --
  -- >>> pPrintStringOpt CheckColorTty defaultOutputOptionsDarkBg{ outputOptionsStringStyle = DoNotEscapeNonPrintable } "\"A \\x42 Ä \\xC4 \\n\""
  -- "A B Ä Ä "
  --
  -- If you change the above example to contain @\x1@, you can see that it is
  -- output as a literal, non-escaped character.  Newlines are still removed
  -- for readability.
  --
  -- Another output style is 'Literal'.  This just outputs all escape characters.
  --
  -- >>> pPrintStringOpt CheckColorTty defaultOutputOptionsDarkBg{ outputOptionsStringStyle = Literal } "\"A \\x42 Ä \\xC4 \\x1 \\n\""
  -- "A \x42 Ä \xC4 \x1 \n"
  --
  -- You can see that all the escape characters get output literally, including
  -- newline.
  } deriving (Eq, Generic, Show, Typeable)

-- | Default values for 'OutputOptions' when printing to a console with a dark
-- background.  'outputOptionsIndentAmount' is 4, and
-- 'outputOptionsColorOptions' is 'defaultColorOptionsDarkBg'.
defaultOutputOptionsDarkBg :: OutputOptions
defaultOutputOptionsDarkBg =
  OutputOptions
  { outputOptionsIndentAmount = 4
  , outputOptionsColorOptions = Just defaultColorOptionsDarkBg
  , outputOptionsStringStyle = EscapeNonPrintable
  }

-- | Default values for 'OutputOptions' when printing to a console with a light
-- background.  'outputOptionsIndentAmount' is 4, and
-- 'outputOptionsColorOptions' is 'defaultColorOptionsLightBg'.
defaultOutputOptionsLightBg :: OutputOptions
defaultOutputOptionsLightBg =
  OutputOptions
  { outputOptionsIndentAmount = 4
  , outputOptionsColorOptions = Just defaultColorOptionsLightBg
  , outputOptionsStringStyle = EscapeNonPrintable
  }

-- | Default values for 'OutputOptions' when printing using using ANSI escape
-- sequences for color.  'outputOptionsIndentAmount' is 4, and
-- 'outputOptionsColorOptions' is 'Nothing'.
defaultOutputOptionsNoColor :: OutputOptions
defaultOutputOptionsNoColor =
  OutputOptions
  { outputOptionsIndentAmount = 4
  , outputOptionsColorOptions = Nothing
  , outputOptionsStringStyle = EscapeNonPrintable
  }

-- | Given 'OutputOptions', disable colorful output if the given handle
-- is not connected to a TTY.
hCheckTTY :: MonadIO m => Handle -> OutputOptions -> m OutputOptions
hCheckTTY h options = liftIO $ conv <$> tty
  where
    conv :: Bool -> OutputOptions
    conv True = options
    conv False = options { outputOptionsColorOptions = Nothing }

    tty :: IO Bool
    tty = hIsTerminalDevice h

-- | Parse a string, and generate an intermediate representation,
-- suitable for passing to any /prettyprinter/ backend.
-- Used by 'Simple.pString' etc.
layoutString :: OutputOptions -> String -> SimpleDocStream AnsiStyle
layoutString opts = exprsToDocStream opts . expressionParse

exprsToDocStream :: OutputOptions -> [Expr] -> SimpleDocStream AnsiStyle
exprsToDocStream opts = annotateAnsi opts . layoutPretty defaultLayoutOptions . exprsToDoc opts

exprsToDoc :: OutputOptions -> [Expr] -> Doc Annotation
exprsToDoc opts = exprs False . preprocess opts
  where
    list open close (CommaSeparated es) = annotate Open open <>
        hcat (intersperse (line <> annotate Comma ",")
          (map (exprs True) es)) <> l <> annotate Close close
      where l = if null es then line' else line
    exprs nested = \case -- 'nested' is True unless this is the very top level
      [] -> mempty
      x : xs -> expr nested x <> hcat (map (expr True) xs)
    expr nested x = applyWhen (isSimple x) group $
      applyWhen nested ((line <>) . flatAlt (indent indentAmount (go x))) $ go x
    isSimple = \case -- should this expression be contracted on to one line?
      (getList -> Just [[e]]) -> isSimple e
      (getList -> Just (_:_)) -> False
      StringLit s -> '\n' `notElem` s
      Other s -> '\n' `notElem` s
      _ -> True
    getList = \case
      Brackets (CommaSeparated xs) -> Just xs
      Braces (CommaSeparated xs) -> Just xs
      Parens (CommaSeparated xs) -> Just xs
      _ -> Nothing
    go = \case
      Brackets xss -> list "[" "]" xss
      Braces xss -> list "{" "}" xss
      Parens xss -> list "(" ")" xss
      StringLit s -> join enclose (annotate Quote "\"") $ annotate String $ pretty s
      CharLit s -> join enclose (annotate Quote "'") $ annotate String $ pretty s
      Other s -> pretty s
      NumberLit n -> annotate Num $ pretty n
    indentAmount = outputOptionsIndentAmount opts

preprocess :: OutputOptions -> [Expr] -> [Expr]
preprocess opts = map one . removeEmptyOther
  where
    one = \case
      Brackets xss -> Brackets $ cs xss
      Braces xss -> Braces $ cs xss
      Parens xss -> Parens $ cs xss
      StringLit s -> StringLit $
        case outputOptionsStringStyle opts of
          Literal -> s
          EscapeNonPrintable -> escapeNonPrintable $ readStr s
          DoNotEscapeNonPrintable -> readStr s
      CharLit s -> CharLit s
      Other s -> Other $ shrinkWhitespace $ strip s
      NumberLit n -> NumberLit n
    cs (CommaSeparated ess) = CommaSeparated $ map (preprocess opts) ess
    readStr :: String -> String
    readStr s = fromMaybe s . readMaybe $ '"': s ++ "\""

removeEmptyOther :: [Expr] -> [Expr]
removeEmptyOther = filter $ \case
  Other s -> any (not . isSpace) s
  _ -> True

applyWhen :: Bool -> (a -> a) -> a -> a
applyWhen = flip $ bool id

-- | Traverse the stream, using a 'Tape' to keep track of the current color.
annotateAnsi :: OutputOptions -> SimpleDocStream Annotation
  -> SimpleDocStream AnsiStyle
annotateAnsi opts ds = case outputOptionsColorOptions opts of
  Nothing -> unAnnotateS ds
  Just ColorOptions {..} -> evalState (traverse style ds) initialTape
    where
      style :: MonadState (Tape AnsiStyle) m => Annotation -> m AnsiStyle
      style = \case
        Open -> modify moveR *> gets tapeHead
        Close -> gets tapeHead <* modify moveL
        Comma -> gets tapeHead
        Quote -> pure colorQuote
        String -> pure colorString
        Num -> pure colorNum
      initialTape = Tape
        { tapeLeft = streamRepeat colorError
        , tapeHead = colorError
        , tapeRight = streamCycle $ fromMaybe (pure mempty)
            $ nonEmpty $ colorRainbowParens
        }

-- | An abstract annotation type, representing the various elements
-- we may want to highlight.
data Annotation
  = Open
  | Close
  | Comma
  | Quote
  | String
  | Num

-- | Replace non-printable characters with hex escape sequences.
--
-- >>> escapeNonPrintable "\x1\x2"
-- "\\x1\\x2"
--
-- Newlines will not be escaped.
--
-- >>> escapeNonPrintable "hello\nworld"
-- "hello\nworld"
--
-- Printable characters will not be escaped.
--
-- >>> escapeNonPrintable "h\101llo"
-- "hello"
escapeNonPrintable :: String -> String
escapeNonPrintable input = foldr escape "" input

-- Replace an unprintable character except a newline
-- with a hex escape sequence.
escape :: Char -> ShowS
escape c
  | isPrint c || c == '\n' = (c:)
  | otherwise = ('\\':) . ('x':) . showHex (ord c)

shrinkWhitespace :: String -> String
shrinkWhitespace (' ':' ':t) = shrinkWhitespace (' ':t)
shrinkWhitespace (h:t) = h : shrinkWhitespace t
shrinkWhitespace "" = ""

strip :: String -> String
strip = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | A bidirectional Turing-machine tape:
-- infinite in both directions, with a head pointing to one element.
data Tape a = Tape
  { tapeLeft  :: Stream a -- ^ the side of the 'Tape' left of 'tapeHead'
  , tapeHead  :: a        -- ^ the focused element
  , tapeRight :: Stream a -- ^ the side of the 'Tape' right of 'tapeHead'
  } deriving Show
-- | Move the head left
moveL :: Tape a -> Tape a
moveL (Tape (l :.. ls) c rs) = Tape ls l (c :.. rs)
-- | Move the head right
moveR :: Tape a -> Tape a
moveR (Tape ls c (r :.. rs)) = Tape (c :.. ls) r rs

-- | An infinite list
data Stream a = a :.. Stream a deriving Show
-- | Analogous to 'repeat'
streamRepeat :: t -> Stream t
streamRepeat x = x :.. streamRepeat x
-- | Analogous to 'cycle'
-- While the inferred signature here is more general,
-- it would diverge on an empty structure
streamCycle :: NonEmpty a -> Stream a
streamCycle xs = foldr (:..) (streamCycle xs) xs
