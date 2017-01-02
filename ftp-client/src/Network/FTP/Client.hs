module Network.FTP.Client (
    withFTP,
    login,
    pasv,
    nlst,
    retr,
    stor,
    rename,
    dele,
    cwd,
    size,
    mkd,
    rmd,
    pwd,
    quit,
    createDataSocket,
    sendCommand,
    sendCommands,
    FTPCommand(..),
    RTypeCode(..),
    ControlConnection(..),
    ccClose,
    DataConnection(..),
    dcClose,
    DataSocket(..),
    getLineResp,
    PortActivity(..),
    createSendDataCommand,
    getMultiLineResp,
    sendLine
) where

import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString as B
import Data.List
import Data.Attoparsec.ByteString.Char8
import Network.Socket
import System.IO
import Data.Monoid ((<>), mconcat)
import Control.Exception
import Control.Monad
import Data.Bits

parse227 :: Parser (String, Int)
parse227 = do
    skipWhile (/= '(') *> char '('
    [h1,h2,h3,h4,p1,p2] <- many1 digit `sepBy` char ','
    let host = intercalate "." [h1,h2,h3,h4]
        highBits = read p1
        lowBits = read p2
        portNum = (highBits `shift` 8) + lowBits
    return (host, portNum)

parse257 :: Parser String
parse257 = do
    char '"'
    C.unpack <$> takeTill (== '"')

newtype ControlConnection = CC Handle
newtype DataConnection = DC Handle
newtype DataSocket = DS Socket

ccClose :: ControlConnection -> IO ()
ccClose (CC h) = hClose h

dcClose :: DataConnection -> IO ()
dcClose (DC h) = hClose h

dcGetContents :: DataConnection -> IO C.ByteString
dcGetContents (DC h) = C.hGetContents h

data FTPResponse = FTPResponse {
    frStatus :: ResponseStatus,
    frCode :: Int,
    frMessage :: C.ByteString
}

instance Show FTPResponse where
    show fr = (show $ frCode fr) <> " " <> (C.unpack $ frMessage fr)

data ResponseStatus
    = Wait
    | Success
    | Continue
    | FailureRetry
    | Failure
    deriving (Show)

responseStatus :: C.ByteString -> ResponseStatus
responseStatus cbs =
    case C.uncons cbs of
        Just ('1', _) -> Wait
        Just ('2', _) -> Success
        Just ('3', _) -> Continue
        Just ('4', _) -> FailureRetry
        _             -> Failure

data RTypeCode = TA | TI

serialzeRTypeCode :: RTypeCode -> String
serialzeRTypeCode TA = "A"
serialzeRTypeCode TI = "I"

data PortActivity = Active | Passive

data FTPCommand
    = User String
    | Pass String
    | Acct String
    | RType RTypeCode
    | Retr String
    | Nlst [String]
    | Port HostAddress PortNumber
    | Stor String
    | List [String]
    | Rnfr String
    | Rnto String
    | Dele String
    | Size String
    | Mkd String
    | Rmd String
    | Cwd String
    | Cdup
    | Pwd
    | Abor
    | Pasv
    | Quit

instance Show FTPCommand where
    show = serializeCommand

formatPort :: HostAddress -> PortNumber -> String
formatPort ha pn =
    let (w1, w2, w3, w4) = hostAddressToTuple ha
        hn = show <$> [w1, w2, w3, w4]
        portParts = show <$> [pn `quot` 256, pn `mod` 256]
    in  intercalate "," (hn <> portParts)

serializeCommand :: FTPCommand -> String
serializeCommand (User user)  = "USER " <> user
serializeCommand (Pass pass)  = "PASS " <> pass
serializeCommand (Acct acct)  = "ACCT " <> acct
serializeCommand (RType rt)   = "TYPE " <> serialzeRTypeCode rt
serializeCommand (Retr file)  = "RETR " <> file
serializeCommand (Nlst [])    = "NLST"
serializeCommand (Nlst args)  = "NLST " <> intercalate " " args
serializeCommand (Port ha pn) = "PORT " <> formatPort ha pn
serializeCommand (Stor loc)   = "STOR " <> loc
serializeCommand (List [])    = "LIST"
serializeCommand (List args)  = "LIST " <> intercalate " " args
serializeCommand (Rnfr from)  = "RNFR " <> from
serializeCommand (Rnto to)    = "RNTO " <> to
serializeCommand (Dele file)  = "DELE " <> file
serializeCommand (Size file)  = "SIZE " <> file
serializeCommand (Mkd dir)    = "MKD " <> dir
serializeCommand (Rmd dir)    = "RMD " <> dir
serializeCommand (Cwd dir)    = "CWD " <> dir
serializeCommand Cdup         = "CDUP"
serializeCommand Pwd          = "PWD"
serializeCommand Abor         = "ABOR"
serializeCommand Pasv         = "PASV"
serializeCommand Quit         = "QUIT"

stripCLRF = C.takeWhile $ (&&) <$> (/= '\r') <*> (/= '\n')

getLineResp :: Handle -> IO C.ByteString
getLineResp h = stripCLRF <$> C.hGetLine h

getMultiLineResp :: Handle -> IO FTPResponse
getMultiLineResp h = do
    line <- getLineResp h
    let (code, rest) = C.splitAt 3 line
    message <- if C.head rest == '-'
        then loopMultiLine h code line
        else return line
    return $ FTPResponse
        (responseStatus code)
        (read $ C.unpack code)
        (C.drop 4 message)

loopMultiLine :: Handle -> C.ByteString -> C.ByteString -> IO C.ByteString
loopMultiLine h code line = do
    nextLine <- getLineResp h
    let multiLine = line <> "\n" <> nextLine
        nextCode = C.take 3 nextLine
    if nextCode == code
        then return multiLine
        else loopMultiLine h nextCode multiLine

sendLine :: Handle -> C.ByteString -> IO ()
sendLine h dat = C.hPut h $ dat <> "\r\n"

sendCommand :: ControlConnection -> FTPCommand -> IO FTPResponse
sendCommand (CC h) fc = do
    let command = serializeCommand fc
    print $ "Sending: " <> command
    sendLine h $ C.pack command
    resp <- getMultiLineResp h
    print $ "Recieved: " <> (show resp)
    return resp

sendCommands :: ControlConnection -> [FTPCommand] -> IO [FTPResponse]
sendCommands cc = mapM (sendCommand cc)

createSocket :: Maybe String -> Int -> AddrInfo -> IO (Socket, AddrInfo)
createSocket host portNum hints = do
    addr:_ <- getAddrInfo (Just hints) host (Just $ show portNum)
    print $ "Addr: " <> show addr
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    return (sock, addr)

createSocketPassive :: String -> Int -> IO Socket
createSocketPassive host portNum = do
    let hints = defaultHints {
        addrSocketType = Stream
    }
    (sock, addr) <- createSocket (Just host) portNum hints
    connect sock (addrAddress addr)
    print "Connected"
    return sock

createSocketActive :: ControlConnection -> IO Socket
createSocketActive cc = do
    let hints = defaultHints {
        addrSocketType = Stream,
        addrFlags = [AI_PASSIVE]
    }
    (sock, addr) <- createSocket Nothing 0 hints
    bind sock (addrAddress addr)
    listen sock 1
    print "Listening"
    return sock

createHandle :: String -> Int -> IO Handle
createHandle host portNum = do
    sock <- createSocketPassive host portNum
    socketToHandle sock ReadWriteMode

withHandle :: String -> Int -> (Handle -> IO a) -> IO a
withHandle host portNum = bracket (createHandle host portNum) hClose

withFTP :: String -> Int -> (ControlConnection -> FTPResponse -> IO a) -> IO a
withFTP host portNum f = withHandle host portNum $ \h -> do
    resp <- getMultiLineResp h
    f (CC h) resp

createDataSocketPasv :: ControlConnection -> IO DataSocket
createDataSocketPasv ch = do
    (host, portNum) <- pasv ch
    print $ "Host: " <> host
    print $ "Port: " <> show portNum
    socket <- createSocketPassive host portNum
    return $ DS socket

createDataSocketActive :: ControlConnection -> IO DataSocket
createDataSocketActive cc = do
    socket <- createSocketActive cc
    (SockAddrInet sPort sHost) <- getSocketName socket
    port cc sHost sPort
    return $ DS socket

createDataSocket :: ControlConnection -> PortActivity -> IO DataSocket
createDataSocket cc Active  = createDataSocketActive cc
createDataSocket cc Passive = createDataSocketPasv cc

getAllLineResp :: DataConnection -> IO C.ByteString
getAllLineResp (DC h) = getAllLineResp' h []
    where
        getAllLineResp' h ret = do
            eof <- hIsEOF h
            if eof
                then return $ C.intercalate "\n" ret
                else do
                    line <- getLineResp h
                    getAllLineResp' h (ret <> [line])

acceptData :: Socket -> PortActivity -> IO Socket
acceptData sock Passive = return sock
acceptData sock Active = do
    (socket, _) <- accept sock
    return socket

createSendDataCommand
    :: ControlConnection
    -> PortActivity
    -> [FTPCommand]
    -> IO DataConnection
createSendDataCommand cc pa cmds = do
    (DS socket) <- createDataSocket cc pa
    sendCommands cc cmds
    acceptedSock <- acceptData socket pa
    h <- socketToHandle acceptedSock ReadWriteMode
    return $ DC h

sendDataCommand
    :: ControlConnection
    -> PortActivity
    -> [FTPCommand]
    -> (DataConnection -> IO a)
    -> IO a
sendDataCommand cc@(CC ch) pa cmds f = do
    x <- bracket (createSendDataCommand cc pa cmds) dcClose f
    resp <- getMultiLineResp ch
    print $ "Recieved: " <> (show resp)
    return x

login :: ControlConnection -> String -> String -> IO FTPResponse
login cc user pass = last <$> sendCommands cc [User user, Pass pass]

pasv :: ControlConnection -> IO (String, Int)
pasv cc = do
    resp <- sendCommand cc Pasv
    let (Right (host, portNum)) = parseOnly parse227 (frMessage resp)
    return (host, portNum)

port :: ControlConnection -> HostAddress -> PortNumber -> IO FTPResponse
port cc ha pn = sendCommand cc (Port ha pn)

acct :: ControlConnection -> String -> IO FTPResponse
acct cc pass = sendCommand cc (Acct pass)

nlst :: ControlConnection -> [String] -> IO C.ByteString
nlst cc args = sendDataCommand cc Passive [RType TA, Nlst args] getAllLineResp

retr :: ControlConnection -> String -> IO C.ByteString
retr cc path = sendDataCommand cc Passive [RType TI, Retr path] dcGetContents

list :: ControlConnection -> [String] -> IO C.ByteString
list cc args = sendDataCommand cc Passive [RType TA, List args] dcGetContents

stor :: ControlConnection -> String -> B.ByteString -> RTypeCode -> IO ()
stor cc loc dat rtype = do
    sendDataCommand cc Passive [RType rtype, Stor loc] $ \(DC h) ->
        case rtype of
            TA -> void $ mapM (sendLine h) $ C.split '\n' dat
            TI -> C.hPut h dat

rename :: ControlConnection -> String -> String -> IO FTPResponse
rename cc from to = do
        res <- sendCommand cc (Rnfr from)
        case frStatus res of
            Continue -> sendCommand cc (Rnto to)
            _ -> return res

dele :: ControlConnection -> String -> IO FTPResponse
dele cc file = sendCommand cc (Dele file)

cwd :: ControlConnection -> String -> IO FTPResponse
cwd cc dir = do
    sendCommand cc $ if dir == ".."
        then Cdup
        else Cwd dir

size :: ControlConnection -> String -> IO Int
size cc file = do
    resp <- sendCommand cc (Size file)
    return $ read $ C.unpack $ frMessage resp

mkd :: ControlConnection -> String -> IO String
mkd cc dir = do
    resp <- sendCommand cc (Mkd dir)
    let (Right dir) = parseOnly parse257 (frMessage resp)
    return dir

rmd :: ControlConnection -> String -> IO FTPResponse
rmd cc dir = sendCommand cc (Rmd dir)

pwd :: ControlConnection -> IO String
pwd cc = do
    resp <- sendCommand cc Pwd
    let (Right dir) = parseOnly parse257 (frMessage resp)
    return dir

quit :: ControlConnection -> IO FTPResponse
quit cc = sendCommand cc Quit
