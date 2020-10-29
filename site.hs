--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
import           Data.Monoid (mappend)
import           Hakyll
import           Hakyll.Core.Configuration
import           Data.Set (Set)
import qualified Data.Set as S
import           Text.Pandoc
import           Text.Pandoc.Extensions


--------------------------------------------------------------------------------
main :: IO ()
main = hakyllWith config $ do

    match "images/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    match (fromList ["about.md", "contact.md"]) $ do
        route   $ setExtension "html"
        compile $ customPandoc
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    match "posts/*" $ do
        route $ setExtension "html"
        compile $ customPandoc
            >>= loadAndApplyTemplate "templates/post.html"    postCtx
            >>= loadAndApplyTemplate "templates/default.html" postCtx
            >>= relativizeUrls

    create ["archive.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let archiveCtx =
                    listField "posts" postCtx (return posts) <>
                    constField "title" "Archives"            <>
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" archiveCtx
                >>= relativizeUrls


    match "index.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let indexCtx =
                    listField "posts" postCtx (return posts) <>
                    defaultContext

            getResourceBody
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/default.html" indexCtx
                >>= relativizeUrls

    match "templates/*" $ compile templateBodyCompiler


--------------------------------------------------------------------------------
postCtx :: Context String
postCtx =  dateField "published" "%d-%m-%Y"
        <> defaultContext
        <> dateField "last" "%d-%m-%Y"

config :: Configuration
config = defaultConfiguration -- removed custom deploy for CircleCI

customExts :: Extensions -- pandoc options
customExts = 
    pandocExtensions 
        `mappend` extensionsFromList [ Ext_native_divs
                                     , Ext_literate_haskell
                                     , Ext_emoji
                                     , Ext_inline_code_attributes
                                     , Ext_inline_notes
                                     ]

writerConfig :: WriterOptions
writerConfig = def { writerExtensions = customExts }

readerConfig :: ReaderOptions
readerConfig = def { readerExtensions = customExts }

customPandoc :: Compiler (Item String)
customPandoc = pandocCompilerWith readerConfig writerConfig
