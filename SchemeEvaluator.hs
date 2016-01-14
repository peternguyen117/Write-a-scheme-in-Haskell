module Main where
import System.IO
import SchemeParser 
import System.Environment
import Control.Monad.Error
import Text.ParserCombinators.Parsec

data LispError = NumArgs Integer [LispVal]
               | TypeMismatch String LispVal
               | Parser ParseError
               | BadSpecialForm String LispVal
               | NotFunction String String
               | UnboundVar String String
               | Default String

showError :: LispError -> String
showError (UnboundVar message varname) = message ++ ": " ++ varname
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func) = message ++ ": " ++ show func
showError (NumArgs expected found) = "Expected " ++ show expected ++
                                     " args; found values " ++ 
                                     (unwords . map showVal) found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected
                                        ++ ", found " ++ show found
showError (Parser parseErr) = "Parse error at" ++ show parseErr

instance Show LispError where show = showError
instance Error LispError where
    noMsg = Default "An error has occurred"
    strMsg = Default

type ThrowsError = Either LispError
trapError action = catchError action (return . show)
extractValue :: ThrowsError a -> a
extractValue (Right val) = val

instance Show LispVal where show = showVal

{-- Custom string representation --}
showVal :: LispVal -> String
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (Char c) =  "'\\\"" ++ [c,'\'']
showVal (List contents) = "(" ++ (unwords . map showVal) contents ++ ")"
showVal (DottedList head tail) = "(" ++ (unwords . map showVal) head 
                                     ++ " . " ++ showVal tail ++ ")"

{-- Our current evaluator, merely just prints out the expr --}
readExpr :: String -> ThrowsError LispVal
readExpr input = case parse (parseExpr <* eof) "lisp" input of
    Left err -> throwError $ Parser err
    Right val -> return val

eval :: LispVal -> ThrowsError LispVal
eval val@(String _) = return val
eval val@(Number _) = return val
eval val@(Bool _) = return val
eval (List [Atom "quote", val]) = return val
eval (List [Atom "if", pred, conseq, alt]) =  -- Can return different types -_-
    do result <- eval pred
       case result of
            Bool False -> eval alt
            otherwise  -> eval conseq
eval (List (Atom func : args)) = mapM eval args >>= apply func

eval badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

apply :: String -> [LispVal] -> ThrowsError LispVal
apply func args = maybe (throwError $ NotFunction "Unrecognized primitive\
                                                   \ function args" func) 
                        ($ args) $ lookup func primitives

primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
              ("-", numericBinop (-)),
              ("*", numericBinop (*)),
              ("/", numericBinop div),
              ("mod", numericBinop mod),
              ("quotient", numericBinop quot),
              ("remainder", numericBinop rem),
              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("/=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("&&", boolBoolBinop (&&)),
              ("||", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string<?", strBoolBinop (<)),
              ("string>?", strBoolBinop (>)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("number?", isNumber),
              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv)]
--              ("string?", isString),
--              ("symbol?", isSymbol),
--              ("symbol->string", symToStr),
--              ("string->symbol", strToSym)]

car :: [LispVal] -> ThrowsError LispVal
car [List (x:xs)]      = return x
car [DottedList (x:xs) _] = return x
car [badArg]              = throwError $ TypeMismatch "pair" badArg
car badArgList            = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x:xs)]           = return $ List xs
cdr [DottedList [_] x]      = return x
cdr [DottedList (_:xs) x]   = return $ DottedList xs x
cdr [badArg]                = throwError $ TypeMismatch "pair" badArg
cdr badArgList              = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []]            = return $ List [x1]
cons [x, List xs]             = return $ List (x:xs)
cons [x, DottedList xs xlast] = return $ DottedList (x:xs) xlast
cons [x1, x2]                 = return $ DottedList [x1] x2
cons badArgList               = throwError $ NumArgs 2 badArgList

eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool arg1), (Bool arg2)]             = return . Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)]         = return . Bool $ arg1 == arg2
eqv [(String arg1), (String arg2)]         = return . Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)]             = return . Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(List arg1), (List arg2)]             = return . Bool $ (length arg1 == 
                                                              length arg2) &&
                                             (all eqvPair $ zip arg1 arg2)
                                where eqvPair (x1, x2) = case eqv [x1, x2] of
                                           Right (Bool val)  -> val
                                           otherwise -> False -- No error handling         
eqv [_,_] = return $ Bool False
eqv badArgList = throwError $ NumArgs 2 badArgList

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] ->
                ThrowsError LispVal

boolBinop unpacker op args = if length args /= 2
                             then throwError $ NumArgs 2 args
                             else do left  <- unpacker $ args !! 0
                                     right <- unpacker $ args !! 1
                                     return $ Bool $ left `op` right

numBoolBinop  = boolBinop unpackNum
strBoolBinop  = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s)   = return $ show s
unpackStr notString  = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool = throwError $ TypeMismatch "boolean" notBool

isNumber :: [LispVal] -> ThrowsError LispVal
isNumber [(Number _)] = return $ Bool True
isNumber _ = return $ Bool False

isString :: [LispVal] -> LispVal
isString [(String _)] = Bool True
isString _ = Bool False

isSymbol :: [LispVal] -> LispVal
isSymbol [Atom _] = Bool True
isSymbol _ = Bool False

symToStr :: [LispVal] -> LispVal
symToStr [Atom s] = String s
symToStr _ = String "YOU SUCK"

strToSym :: [LispVal] -> LispVal
strToSym [String s] = Atom s
strToSym _ = Atom "YOU SUCK2"

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> 
                ThrowsError LispVal

numericBinop op [] = throwError $ NumArgs 2 []
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params = mapM unpackNum params >>= return . Number . foldl1 op
-- numericBinop op params = Number $ foldl1 op $ map unpackNum params

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (String n) = let parsed = reads n in
                           if null parsed
                               then throwError $ TypeMismatch "number" $ String n
                               else return $ fst $ parsed !! 0
unpackNum (List [n]) = unpackNum n
unpackNum notNum = throwError $ TypeMismatch "number" notNum

{- unpackNum (String n) = let parsed = reads n in
                            if null parsed
                                then 0
                                else fst $ parsed !! 0
unpackNum (List [n]) = unpackNum n -}

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: String -> IO String
evalString expr = return $ extractValue $ trapError 
                                          (liftM show $ readExpr expr >>= eval)

evalAndPrint :: String -> IO ()
evalAndPrint expr = evalString expr >>= putStrLn

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pred prompt action = do result <- prompt
                               if pred result
                                  then return ()
                                  else action result >> until_ pred prompt action

runRepl :: IO ()
runRepl = until_ (== "quit") (readPrompt "Lisp>>> ") evalAndPrint

main :: IO ()
main = do args <- getArgs
          case length args of
               0 -> runRepl
               1 -> evalAndPrint $ args !! 0
               otherwise -> putStrLn "Program takes only 0 or 1 argument"

-- main :: IO ()
-- main = do args <- getArgs
--           evaled <- return $ liftM show $ readExpr (args !! 0) >>= eval
--           putStrLn $ extractValue $ trapError evaled
-- main = getArgs >>= putStrLn . show . eval . readExpr . head
-- main = getArgs >>= putStrLn . showVal . readExpr . head

