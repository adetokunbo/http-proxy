{-# LANGUAGE OverloadedStrings #-}

--------------------------------------------------------------------------------
--
-- Copyright (c)  Erik de Castro Lopo <erikd@mega-nerd.com>
-- License : BSD3
--
--------------------------------------------------------------------------------

import Blaze.ByteString.Builder
import Control.Monad.Trans.Resource
import Network.HTTP.Proxy

import Control.Applicative ((<$>))
import Data.Char (isSpace)
import Control.Concurrent (forkIO, killThread)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Trans.Class (lift)
import Data.ByteString.Lex.Integral (readDecimal_)
import Data.Conduit (($$))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Conduit as DC
import qualified Data.Conduit.Binary as CB
import qualified Network.HTTP.Conduit as HC
import qualified Network.HTTP.Types as HT

import TestServer


testProxyPort, testServerPort :: Int
testProxyPort = 31081
testServerPort = 31080


hugeLen :: Int64
hugeLen = 8 * 1000 * 1000 * 1000

main :: IO ()
main = runResourceT $ do
    -- Don't need to do anything with these ThreadIds
    _ <- with (forkIO $ runTestServer testServerPort) killThread
    _ <- with (forkIO $ runProxy testProxyPort) killThread
    testLargeGet  $ "http://localhost:" ++ show testServerPort ++ "/large-get?1000"
    testLargeGet  $ "http://localhost:" ++ show testServerPort ++ "/large-get?" ++ show hugeLen
    testLargePost $ "http://localhost:" ++ show testServerPort ++ "/large-post"
    liftIO $ putStrLn "All test passed"

--------------------------------------------------------------------------------

testLargeGet :: String -> ResourceT IO ()
testLargeGet url = do
    liftIO $ putStr "Testing large GET operation  : "
    request <-
            (\r -> r { HC.checkStatus = \ _ _ -> Nothing })
                <$> lift (HC.parseUrl url)
    httpCheckGetBodySize $ HC.addProxy "localhost" testProxyPort request
    liftIO $ putStrLn "passed"


httpCheckGetBodySize :: HC.Request IO -> ResourceT IO ()
httpCheckGetBodySize req = liftIO $ HC.withManager $ \mgr -> do
    HC.Response st hdrs bdy <- HC.http req mgr
    when (st /= HT.statusOK) $
        error $ "httpCheckGetBodySize : Bad status code : " ++ show st
    let contentLength = readDecimal_ $ fromMaybe "0" $ lookup "content-length" hdrs
    when (contentLength == (0 :: Int64)) $
        error "httpCheckGetBodySize : content-length is zero."
    bdy $$ byteSink contentLength

--------------------------------------------------------------------------------

testLargePost :: String -> ResourceT IO ()
testLargePost url = do
    liftIO $ putStr "Testing large POST operation : "
    request <-
            (\r -> r { HC.method = "POST"
                     , HC.requestBody = requestBodySource hugeLen
                     -- Disable expecptions for non-2XX status codes.
                     , HC.checkStatus = \ _ _ -> Nothing
                     })
                <$> lift (HC.parseUrl url)
    httpCheckPostResponse hugeLen $ HC.addProxy "localhost" testProxyPort request
    liftIO $ putStrLn "passed"


httpCheckPostResponse :: Int64 -> HC.Request IO -> ResourceT IO ()
httpCheckPostResponse postLen req = liftIO $ HC.withManager $ \mgr -> do
    HC.Response st _ bdy <- HC.http req mgr
    when (st /= HT.statusOK) $
        error $ "httpCheckGetBodySize : Bad status code : " ++ show st
    bodyText <- bdy $$ CB.take 1024
    let len = case BS.split ':' (BS.concat (LBS.toChunks bodyText)) of
                ["Post-size", size] -> readDecimal_ $ BS.dropWhile isSpace size
                _ -> error "httpCheckPostResponse : Not able to read Post-size."
    when (len /= postLen) $
        error $ "httpCheckPostResponse : Post length " ++ show len ++ " should have been " ++ show postLen ++ "."


requestBodySource :: Int64 -> HC.RequestBody IO
requestBodySource len =
    HC.RequestBodySource len $ DC.sourceState 0 run
  where
    run :: MonadIO m => Int64 -> ResourceT m (DC.SourceStateResult Int64 Builder)
    run count
        | count >= len = return DC.StateClosed
        | len - count > blockSize64 =
            return $ DC.StateOpen (count + blockSize64) bbytes
        | otherwise =
            let n = len - count
            in return $ DC.StateOpen (count + n) $ fromByteString $ BS.take blockSize bsbytes

    blockSize = 4096
    blockSize64 = fromIntegral blockSize :: Int64
    bsbytes = BS.replicate blockSize '?'
    bbytes = fromByteString bsbytes
