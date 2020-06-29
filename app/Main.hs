module Main where

-- This is a small executable that will pretty-print anything from stdin.
-- It can be installed to `~/.local/bin` if you enable the flag `buildexe` like so:
--
-- @
--   $ stack install pretty-simple-2.0.1.1 --flag pretty-simple:buildexe
-- @
--
-- When you run it, you can paste something you want formatted on stdin, then
-- press @Ctrl-D@.  It will print the formatted version on stdout:
--
-- @
--   $ pretty-simple
--   [(Just 3, Just 4)]
--
--   ^D
--
--   [
--       ( Just 3
--       , Just 4
--       )
--   ]
-- @

import Data.Text (unpack)
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy.IO as LT
import Options.Applicative 
       ( Parser, ReadM, execParser, fullDesc, help, helper, info, long
       , option, progDesc, readerError, short, showDefaultWith, str, value, (<**>))
import Data.Monoid ((<>))
import Text.Pretty.Simple 
       ( pStringOpt, OutputOptions
       , defaultOutputOptionsDarkBg
       , defaultOutputOptionsLightBg
       , defaultOutputOptionsNoColor
       )

data Color = DarkBg
           | LightBg
           | NoColor

newtype Args = Args { color :: Color }

colorReader :: ReadM Color
colorReader = do
  string <- str
  case string of
    "dark-bg"  -> pure DarkBg
    "light-bg" -> pure LightBg
    "no-color" -> pure NoColor
    x          -> readerError $ "Could not parse " <> x <> " as a color."

args :: Parser Args
args = Args
    <$> option colorReader
        ( long "color"
       <> short 'c'
       <> help "Select printing color. Available options: dark-bg (default), light-bg, no-color."
       <> showDefaultWith (\_ -> "dark-bg")
       <> value DarkBg
        )

main :: IO ()
main = do
  args' <- execParser opts
  input <- T.getContents
  let printOpt = getPrintOpt $ color args'
      output = pStringOpt printOpt $ unpack input
  LT.putStr output
  where
    opts = info (args <**> helper)
      ( fullDesc
     <> progDesc "Format Haskell data types with indentation and highlighting"
      )

    getPrintOpt :: Color -> OutputOptions
    getPrintOpt DarkBg  = defaultOutputOptionsDarkBg
    getPrintOpt LightBg = defaultOutputOptionsLightBg
    getPrintOpt NoColor = defaultOutputOptionsNoColor
