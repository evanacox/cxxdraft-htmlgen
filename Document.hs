{-# OPTIONS_GHC -fno-warn-tabs #-}
{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

module Document (
	CellSpan(..), Cell(..), RowSepKind(..), Row(..), Element(..), Elements, Paragraph(..),
	Section(..), Chapter(..), Draft(..), Table(..), Figure(..), Item(..),
	IndexPath, IndexComponent(..), IndexCategory, Index, IndexTree, IndexNode(..), IndexEntry(..), IndexKind(..),
	indexKeyContent, indexCatName, sections, SectionKind(..), mergeIndices, withSubsections,
	coreChapters, libChapters, figures, tables, tableByAbbr, figureByAbbr, elemTex,
	LaTeX) where

import Text.LaTeX.Base.Syntax (LaTeX(..), TeXArg(..), MathType(Dollar))
import Data.Text (Text, replace)
import qualified Data.Text as Text
import qualified Data.List as List
import Data.Function (on)
import Prelude hiding (take, (.), takeWhile, (++), lookup, readFile)
import Data.Char (ord, isAlphaNum, toLower)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (listToMaybe)
import Data.String (IsString)
import Util ((.), (++), greekAlphabet)

-- Document structure:

data CellSpan = Normal | Multicolumn { width :: Int, colspec :: LaTeX } deriving Show
data Cell a = Cell { cellSpan :: CellSpan, content :: a } deriving Show
data RowSepKind = RowSep | CapSep | Clines [(Int, Int)] | NoSep deriving Show
data Row a = Row { rowSep :: RowSepKind, cells :: [Cell a] } deriving Show

data Table = Table
	{ tableNumber :: Int
	, tableCaption :: LaTeX
	, columnSpec :: LaTeX
	, tableAbbrs :: [LaTeX]
	, tableBody :: [Row Elements]
	, tableSection :: Section }
	deriving Show

data Figure = Figure
	{ figureNumber :: Int
	, figureName :: LaTeX
	, figureAbbr :: LaTeX
	, figureSvg :: Text
	, figureSection :: Section }
	deriving Show

data Item = Item
	{ itemNumber :: Maybe [Int]
	, itemContent :: Elements }
	deriving Show

data Element
	= LatexElements [LaTeX]
	| Enumerated { enumCmd :: String, enumItems :: [Item] }
	| Bnf String LaTeX
	| TableElement Table
	| Tabbing LaTeX
	| FigureElement Figure
	| Footnote { footnoteNumber :: Int, footnoteContent :: Elements }
	| Codeblock { code :: LaTeX }
	| Minipage Elements
	deriving Show

-- We don't represent examples as elements with nested content
-- because sometimes they span multiple (numbered) paragraphs.

type Elements = [Element]

data SectionKind
	= NormalSection { _level :: Int }
	| DefinitionSection { _level :: Int }
	| InformativeAnnexSection
	| NormativeAnnexSection
	deriving (Eq, Show)

data Chapter = NormalChapter | InformativeAnnex | NormativeAnnex
	deriving (Eq, Show)

data Paragraph = Paragraph
	{ paraNumber :: Maybe Int
	, paraInItemdescr :: Bool
	, paraElems :: Elements }
	deriving Show

data Section = Section
	{ abbreviation :: LaTeX
	, sectionName :: LaTeX
	, paragraphs :: [Paragraph]
	, subsections :: [Section]
	, sectionNumber :: Int
	, chapter :: Chapter
	, parents :: [Section] -- if empty, this is the chapter
	}
	deriving Show

instance Eq Section where
	x == y = abbreviation x == abbreviation y

data Draft = Draft
	{ commitUrl :: Text
	, chapters  :: [Section]
	, index     :: Index }

-- Indices:

data IndexComponent = IndexComponent { indexKey, indexFormatting :: LaTeX }
	deriving (Eq, Show)

type IndexPath = [IndexComponent]

data IndexKind = See { _also :: Bool, _ref :: LaTeX } | IndexOpen | IndexClose | DefinitionIndex
	deriving Show

type IndexCategory = Text

type Index = Map IndexCategory IndexTree

data IndexEntry = IndexEntry
	{ indexEntrySection :: Section
	, indexEntryKind :: Maybe IndexKind
	, indexPath :: IndexPath }

type IndexTree = Map IndexComponent IndexNode

data IndexNode = IndexNode
	{ indexEntries :: [IndexEntry]
	, indexSubnodes :: IndexTree }

instance Ord IndexComponent where
	compare = compare `on` (\c -> (f (indexKey c), f (indexFormatting c)))
		where
			g :: Char -> Int
			g c
				| isAlphaNum c = ord (toLower c) + 1000
				| otherwise = ord c
			f = map g . Text.unpack . indexKeyContent

mergeIndices :: [Index] -> Index
mergeIndices = Map.unionsWith (Map.unionWith mergeIndexNodes)

mergeIndexNodes :: IndexNode -> IndexNode -> IndexNode
mergeIndexNodes x y = IndexNode
	{ indexEntries = indexEntries x ++ indexEntries y
	, indexSubnodes = Map.unionWith mergeIndexNodes (indexSubnodes x) (indexSubnodes y) }

indexKeyContent :: LaTeX -> Text
indexKeyContent = ikc
	where
		ikc (TeXRaw t) = replace "\n" " " t
		ikc (TeXSeq x y) = ikc x ++ ikc y
		ikc TeXEmpty = ""
		ikc (TeXComm "texttt" [FixArg x]) = ikc x
		ikc (TeXComm "textit" [FixArg x]) = ikc x
		ikc (TeXComm "mathsf" [FixArg x]) = ikc x
		ikc (TeXCommS "xspace") = "_"
		ikc (TeXCommS "Cpp") = "C++"
		ikc (TeXCommS "&") = "&"
		ikc (TeXCommS "%") = "%"
		ikc (TeXCommS "-") = ""
		ikc (TeXCommS "ell") = "ℓ"
		ikc (TeXCommS "~") = "~"
		ikc (TeXCommS "#") = "#"
		ikc (TeXCommS "{") = "{"
		ikc (TeXCommS "}") = "}"
		ikc (TeXCommS "caret") = "^"
		ikc (TeXCommS s)
			| Just c <- List.lookup s greekAlphabet = Text.pack [c]
		ikc (TeXCommS "tilde") = "~"
		ikc (TeXCommS "^") = "^"
		ikc (TeXCommS "\"") = "\""
		ikc (TeXCommS "") = ""
		ikc (TeXCommS "x") = "TODO"
		ikc (TeXCommS "textbackslash") = "\\";
		ikc (TeXCommS "textunderscore") = "_";
		ikc (TeXComm "discretionary" _) = ""
		ikc (TeXBraces x) = ikc x
		ikc (TeXMath Dollar x) = ikc x
		ikc (TeXComm "grammarterm_" [_, FixArg x]) = ikc x
		ikc x = error $ "indexKeyContent: unexpected: " ++ show x

indexCatName :: (Eq b , IsString a, IsString b) => b -> a
indexCatName "impldefindex" = "Index of implementation-defined behavior"
indexCatName "libraryindex" = "Index of library names"
indexCatName "generalindex" = "Index"
indexCatName _ = error "indexCatName"

-- Gathering sections/tables/figures:

class Sections a where sections :: a -> [Section]

instance Sections Section where sections s = s : concatMap sections (subsections s)

instance Sections Draft where sections = concatMap sections . chapters

class Tables a where tables :: a -> [Table]

instance Tables a => Tables [a] where tables = concatMap tables
instance Tables a => Tables (Maybe a) where tables = maybe [] tables

instance Tables Section where
	tables Section{..} = (paragraphs >>= paraElems >>= tables) ++ (subsections >>= tables)

instance Tables Element where
	tables (TableElement t) = [t]
	tables _ = []

instance Tables Draft where tables = tables . chapters

class Figures a where figures :: a -> [Figure]

instance Figures a => Figures [a] where figures = concatMap figures
instance Figures a => Figures (Maybe a) where figures = maybe [] figures

instance Figures Section where
	figures Section{..} = (paragraphs >>= paraElems >>= figures) ++ (subsections >>= figures)

instance Figures Element where
	figures (FigureElement f) = [f]
	figures _ = []

instance Figures Draft where figures = figures . chapters

-- Misc:

withSubsections :: Section -> [Section]
withSubsections s = s : concatMap withSubsections (subsections s)

elemTex :: Element -> [LaTeX]
elemTex (LatexElements l) = l
elemTex (Enumerated _ e) = map itemContent e >>= (>>= elemTex)
elemTex (Bnf _ l) = [l]
elemTex (Codeblock c) = [c]
elemTex (Minipage l) = l >>= elemTex
elemTex (Footnote _ c) = c >>= elemTex
elemTex (Tabbing t) = [t]
elemTex (TableElement t) = tableBody t >>= rowTex
	where
		rowTex :: Row Elements -> [LaTeX]
		rowTex r = content . cells r >>= (>>= elemTex)
elemTex (FigureElement _) = []

tableByAbbr :: Draft -> LaTeX -> Maybe Table
	-- only returns Maybe because some of our tables are broken
tableByAbbr d a = listToMaybe [ t | t <- tables d, a `elem` tableAbbrs t ]

figureByAbbr :: Draft -> LaTeX -> Figure
figureByAbbr d a = case [ f | f <- figures d, a == figureAbbr f ] of
	[f] -> f
	_ -> error $ "figureByAbbr: " ++ show a

splitChapters :: Draft -> ([Section], [Section])
splitChapters = span ((/= "library") . abbreviation) . chapters

coreChapters, libChapters :: Draft -> [Section]
coreChapters = fst . splitChapters
libChapters = snd . splitChapters
