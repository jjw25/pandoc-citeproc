{-# LANGUAGE OverloadedStrings, TypeSynonymInstances, FlexibleInstances,
    ScopedTypeVariables#-}
import System.Exit
import Data.Aeson
import System.FilePath
import System.Directory
import Data.List (intercalate, sort)
import qualified Data.Vector as V
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Text.CSL.Style
import Text.CSL.Parser (parseCSL')
import Text.CSL
import Control.Monad
import Control.Applicative
import qualified Data.ByteString.Lazy as BL
import System.IO.Unsafe

data TestCase = TestCase{
    testMode          :: Mode        -- mode
  , testBibopts       :: BibOpts     -- bibsection
  , testCitations     :: [CiteObject] -- citations
  , testCitationItems :: Citations   -- citation-items
  , testCsl           :: Style       -- csl
  , testAbbreviations :: [Abbrev]    -- abbreviations
  , testReferences    :: [Reference] -- input
  , testResult        :: String      -- result
  } deriving (Show)

data Mode = CitationMode | BibliographyMode deriving Show

instance FromJSON Mode where
  parseJSON (String "citation")     = return CitationMode
  parseJSON (String "bibliography") = return BibliographyMode
  parseJSON _                       = fail "Unknown mode"

instance FromJSON BibOpts where
  parseJSON (Object v) = do
    quash <- v .:? "quash".!= []
    (v .: "select" >>= \x -> return $ Select x quash)
     <|>
     (v .: "include" >>= \x -> return $ Include x quash)
     <|>
     (v .: "exclude" >>= \x -> return $ Exclude x quash)
  parseJSON _ = return $ Select [] []

instance FromJSON TestCase where
  parseJSON (Object v) = TestCase <$>
              v .:  "mode" <*>
              v .:? "bibsection" .!= Select [] [] <*>
              v .:? "citations" .!= [] <*>
              v .:? "citation_items" .!= [] <*>
              v .:  "csl" <*>
              v .:? "abbreviations" .!= [] <*>
              v .:  "input" <*>
              v .:  "result"
  parseJSON _ = fail "Could not parse test case"

instance FromJSON [Abbrev] where
  parseJSON x = case fromJSON x of
                     Success (m :: M.Map String
                                      (M.Map String
                                         (M.Map String String))) ->
                       return $ M.toList $ M.map M.toList m
                     _ -> return []

instance FromJSON Affix where
  parseJSON (String s) = pure $ PlainText (T.unpack s)
  parseJSON _          = fail "Could not parse affix"

instance FromJSON Cite where
  parseJSON (Object v) = Cite <$>
              v .: "id" <*>
              v .:? "prefix" .!= PlainText "" <*>
              v .:? "suffix" .!= PlainText "" <*>
              v .:? "label" .!= "" <*>
              (v .: "locator"  <|> (show :: Int -> String) <$> (v .: "locator") <|> pure "") <*>
              v .:? "note-number" .!= "" <*>
              v .:? "position" .!= "" <*>
              v .:? "near-note" .!= False <*>
              v .:? "author-in-text" .!= False <*>
              v .:? "suppress-author" .!= False <*>
              v .:? "cite-hash" .!= 0
  parseJSON _ = fail "Could not parse Cite"

newtype CiteObject =
        CiteObject { unCiteObject :: [Cite] } deriving Show

instance FromJSON CiteObject where
  parseJSON (Array v) =
    case fromJSON (Array v) of
         Success [Object x, Array _, Array _] ->
                            CiteObject <$> x .: "citationItems"
         Error e         -> fail $ "Could not parse CiteObject: " ++ e
         x               -> fail $ "Could not parse CiteObject" ++ show x
  parseJSON x = fail $ "Could not parse CiteObject " ++ show x

instance FromJSON [CiteObject] where
  parseJSON (Array v) = mapM parseJSON $ V.toList v
  parseJSON _ = return []

instance FromJSON [[Cite]] where
  parseJSON (Array v) = mapM parseJSON $ V.toList v
  parseJSON _ = return []

instance FromJSON Style where
  parseJSON (String s) = return $ unsafePerformIO $ parseCSL'
                         $ BL.fromChunks [T.encodeUtf8 s]
  parseJSON _ = fail "Could not parse Style"

data TestResult =
  Passed | Failed{ expectedValue :: String
                 , actualValue   :: String }
  deriving (Show)

testDir :: FilePath
testDir = "." </> "citeproc-test" </> "processor-tests" </> "machines"

runTest :: FilePath -> IO TestResult
runTest path = do
  putStrLn path
  raw <- BL.readFile path
  let testCase = either error id $ eitherDecode raw
  let procOpts = ProcOpts (testBibopts testCase)
  let style    = (testCsl testCase) {
                        styleAbbrevs = testAbbreviations testCase }
  let refs     = testReferences testCase
  let cites    = map unCiteObject (testCitations testCase) ++ testCitationItems testCase
  let cites'   = if null cites
                    then map (\ref -> [emptyCite{ citeId = refId ref}]) refs
                    else cites
  let expected = testResult testCase
  let mode     = testMode testCase

  let result   = intercalate "\n" $ map (renderPlainStrict) $
                 (case mode of {CitationMode -> citations; _ -> bibliography})
                 $ citeproc procOpts style refs cites'
  if result == expected
     then return Passed
     else do
       putStrLn $ "FAILED! EXPECTED:"
       putStrLn expected
       putStrLn "GOT:"
       putStrLn result
       return $ Failed expected result

main :: IO ()
main = do
  testFiles <- (map (testDir </>) . sort .
                filter (\f -> takeExtension f == ".json"))
              <$> getDirectoryContents testDir
  results <- mapM runTest testFiles
  let isPass Passed = True
      isPass _      = False
  let numpasses = length $ filter isPass results
  let numfailures = length $ filter (not . isPass) results
  exitWith $ if numfailures == 0
                then ExitSuccess
                else ExitFailure numfailures
