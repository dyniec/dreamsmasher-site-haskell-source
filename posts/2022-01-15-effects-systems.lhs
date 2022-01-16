---
title: a type cosmonaut's guide to effects systems
tags: programming, haskell
published: 2022-01-15
---

\ignore {
\begin{code}
{-# OPTIONS_GHC -fprint-potential-instances, -Wall #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances, RankNTypes, UndecidableInstances, TypeFamilies, GADTs, DerivingStrategies, DerivingVia, GeneralisedNewtypeDeriving, BlockArguments, MultiParamTypeClasses , TypeOperators, DeriveFunctor, InstanceSigs, ScopedTypeVariables, DataKinds, PolyKinds, StandaloneKindSignatures, StandaloneDeriving, TypeApplications #-}
import Control.Monad
import Control.Monad.State hiding (MonadTrans)
import Data.Kind
import Control.Monad.Reader hiding (MonadTrans)
import Data.Foldable (find, traverse_)
import Data.Function
import Data.Text (Text)
import Control.Concurrent (getNumCapabilities)
import Control.Exception
import Data.Functor
import Control.Monad.Except (MonadError (throwError, catchError), runExceptT, ExceptT (ExceptT))
import GHC.Generics (type (:*:))
import Text.Read (readMaybe)

data User = User
selectFrom :: a -> m [b]
selectFrom = undefined
userTable = undefined
userId = undefined
connectDB = undefined
server = undefined
\end{code}
}

I've been playing around with type-level ~~fuckery~~ programming lately, and something in my head finally clicked when it came to libraries like [freer-simple](https://hackage.haskell.org/package/freer-simple) and [polysemy](https://hackage.haskell.org/package/polysemy). For context, Haskell applications usually take one of a few approaches to managing complex contextual interactions:

1. Monad transformer stacks.

Let's say you had a simple CRUD app, that needs to be able to log errors, make database calls, and respond to HTTP requests.

You might define a typeclass like:

\begin{code}
data SomeConnection = SomeConnection

class HasConnection m where
  getConnection :: m SomeConnection

-- or if you're fancy:
-- class HasConnection env wheree
--   getConnection :: Lens' env SomeConnection
\end{code}

and then write any DB-accessing code to be polymorphic over the surrounding context, as long as there's a way to access a database connection:

\begin{code}
getUserById 
  :: (HasConnection m, MonadIO m) 
  => Int -> m (Maybe User)
getUserById id = do
  conn <- getConnection
  users <- selectFrom userTable
  pure $ find ((id ==) . userId) users
\end{code}

To run your app, you could then wrap up any required context into a product type and thread that data along implicitly using a `ReaderT` effect:

\begin{code}
-- class MonadReader r m | m -> r where
--   asks :: (r -> a) -> m a
--   ask :: m r
--   ask = asks id
--
-- newtype ReaderT r m a = ReaderT {runReaderT :: r -> m a}
-- instance Applicative m => MonadReader r (ReaderT r m) where 
--   asks f = ReaderT (pure . f)

data AppCtx = AppCtx 
  { _dbConn :: SomeConnection
  , _numThreads :: Int
  , _apiToken :: Text
  } 

instance MonadReader AppCtx m => HasConnection m where
  getConnection = asks _dbConn
\end{code}

And let's assume that there are some other ops in the meantime that can fail, so we want some way of exiting early. Cue `ExceptT` and `MonadError`:

\begin{code}
-- class MonadError err m where 
--   throwError :: forall a. e -> m a
--   catchError :: m a -> (e -> m a) -> m a 
-- newtype ExceptT e m a = ExceptT {runExceptT :: m (Either e a)}
server 
  :: (HasConnection m, MonadIO m, MonadError String m)
  => m ()
\end{code}

Monad transformers are meant to stack, so after creating your app context:

\begin{code}
connectDB :: Text -> IO (Either String SomeConnection)

mkAppCtx :: Text -> IO (Either String AppCtx)
mkAppCtx tok = do
  eitherConn <- connectDB "Data Source=:memory:"
  forM eitherConn \conn -> do
    threads <- getNumCapabilities
    pure $ AppCtx conn threads tok
\end{code}

It's a simple matter of instantiating the exact order of effects you want, then tearing those pieces down until you reach IO:

\begin{code}
-- ignoring other details because I'm lazy

runApp :: IO ()
runApp = do
  Right ctx <- mkAppCtx "some token"
  -- at this point, server is inferred to have the type
  -- ExceptT String (ReaderT AppCtx IO) ()
  serverRes <- runExceptT $ runReaderT server ctx
  either putStrLn pure serverRes 
\end{code}

You could also flip this stack around since `mkAppCtx` returns an `IO (Either ..)` value:

\begin{code}
runApp' :: IO (Either String ())
runApp' = runExceptT do
  ctx <- ExceptT $ mkAppCtx "some token"
  -- server :: ReaderT AppCtx (ExceptT String IO) ()
  runReaderT server ctx
\end{code}

Semantically and representationally, `server` in both cases is the same, even though their (wrapped) types differ.

Expanding `server` from both examples:

```haskell
server1 :: ExceptT String (ReaderT AppCtx IO) ()
 = ReaderT AppCtx IO (Either String ()) 
 = AppCtx -> IO (Either String ())

server2 :: ReaderT AppCtx (ExceptT String IO) ()
 = ReaderT AppCtx (IO (Either String ()))
 = (AppCtx -> IO (Either String ()))
```

The problem is that not every permutation of a series of monad transformers is equivalent. Let's say you had some stateful effect that could throw an error, like running a block cipher, parsing, etc:

\begin{code}
-- newtype StateT s m a 
--  = StateT {runStateT :: s -> m (a, s)}
-- evalStateT :: StateT s m a -> m a
-- execStateT :: StateT s m a -> m s
-- class MonadState s m where
--   get :: m s
--   put :: s -> m ()
--   modify :: (s -> s) -> m ()
newtype SomeState = SomeState Int deriving newtype (Eq, Show)

someStateOp :: (MonadState SomeState m, MonadIO m, MonadError String m) => m ()
someStateOp = do
  SomeState cur <- get
  when (cur == 69) $ throwError "not cool" 
  liftIO $ print cur
  put (SomeState $ cur + 1)
\end{code}

We could run this in two ways: layer the `ExceptT` on top of the `StateT`, or the other way around.

\begin{code}
res1 :: IO (Either String ((), SomeState))
res1 = runExceptT (runStateT someStateOp (SomeState 0))

res2 :: IO (Either String (), SomeState)
res2 = runStateT (runExceptT someStateOp) (SomeState 0)
\end{code}

What the hell?? Flipping the order of the two effects results in two different types, and differing semantics altogether. If `StateT` is on the outside, we run the risk of losing our state entirely if an error is thrown. 

Expanded:
```haskell
stateOp1 :: StateT SomeState (ExceptT String IO) ()
  = SomeState -> ExceptT String IO ((), SomeState)
  = SomeState -> IO (Either String ((), SomeState)) 

stateOp2 :: ExceptT String (StateT SomeState IO) ()
  = StateT SomeState IO (Either String ())
  = SomeState -> IO (Either String (), SomeState)
```

There's also the issue of extensibility - `mtl`-style transformer stacks are implemented using a type class for each effect (`MonadState`, `MonadError`, `MonadCont`, etc.). Monad transformers are parameterized by the ability to `lift` an operation from a lower monad into a higher one, and the polymorphism of effects are obtained by creating instances for each transformer, for each effect. For instance:

```haskell
-- class MonadTrans (t :: (Type -> Type) -> Type -> Type) where
--   lift :: m a -> t m a

newtype IdT m a = IdT {getIdT :: m a} 
  deriving newtype (Functor, Applicative, Monad)

instance MonadTrans IdT where
  lift = IdT

instance MonadState s m => MonadState s (IdT m) where
  get = lift get
  put = lift . put

instance MonadError e m => MonadError e (IdT m) where
  throwError = lift . throwError
  catchError (IdT act) k = lift $ catchError act (getIdT . k)

-- and so on
```

It's pretty easy to see that this is a ton of boilerplate, and introducing a new effect means writing another row of (pretty trivial) instances. Work on the order of `n^2` is pretty bad. This is worse when you add `MonadIO` into the mix, requiring another set of identical `liftIO = lift . liftIO` instance bodies.

<hr>
<h2>introducing extensible effects</h2>

There's been a ton of research/functional pearls published on the use of a combination of type-indexed functors and free monads to write expressive code with minimal boilerplate. One of my favourite such papers is [Data types a la carte](http://www.cs.ru.nl/~W.Swierstra/Publications/DataTypesALaCarte.pdf) by Wouter Sweirstra. He explores the use of fixed-points along with typed unions to create syntax trees that can be interpreted generically, while being open to extension/additional operations as needed.

The gist of the paper is that you can define a simple coproduct of two functors:

\begin{code}
data (f :+: g) a = InL (f a) | InR (g a) deriving Functor
infixr 7 :+:
\end{code}

Along with a fixed point over functors:

\begin{code}
newtype Fix f = Fix (f (Fix f)) 
\end{code}

to create what's essentially a list of nested contexts, that can be folded into a summary value using an F-algebra:

\begin{code}
foldExpr :: Functor f => (f a -> a) -> Fix f -> a
foldExpr fold (Fix f) = fold (foldExpr fold <$> f)
\end{code}

Now I bet you're thinking, "how does this even terminate???", and you're right if `f` is instantiated to some functor like `Identity`. The trick is to use functors with a phantom type as your base case (forming the leaves of the expression):

\begin{code}
newtype Val a = Val Int 
  deriving newtype (Eq, Show, Num)
  deriving stock Functor
\end{code}

And the nodes:

\begin{code}
data Add a = Add a a deriving (Eq, Show, Functor)
\end{code}

Now the coproduct of these two types is:

\begin{code}
type ValOrAdd = (Val :+: Add)
\end{code}

This type is isomorphic to what we'd usually reach for in these situations, which is a simple sum type:

\begin{code}
data AST = ASTVal Int | ASTAdd AST AST
\end{code}

If we want to add another operation, we can extend our sum type inductively since `(:+:)` is itself a functor:

\begin{code}
data Mul a = Mul a a deriving (Eq, Show, Functor)

type ValOrAddOrMul = (Val :+: Add :+: Mul)
\end{code}

Similar to our monad transformer stacks, the order of our effects is just the order of our coproduct. The difference is that we've centralized things to revolve around compositions of `:+:`, instead of treating each node as a distinct type with its own effect AND implementation.

For clarity, we know that there's an injection from a functor `f` to its coproduct with another functor, `f :+: g`:

\begin{code}
class (Functor sub, Functor sup) => sub :<: sup where
  -- inject
  inj :: sub a -> sup a
  -- project
  prj :: sup a -> Maybe (sub a)

-- reflexivity
instance (Functor f) => f :<: f where
  inj = id
  prj = Just

-- compare with `lift` from `MonadTrans`
instance (Functor f, Functor g) => f :<: (f :+: g) where
  inj = InL
  prj (InL fa) = Just fa
  prj (InR ga) = Nothing

-- induction on a list of functors: `f` isn't in the head, but exists in the tail
instance {-# OVERLAPPABLE #-} 
  (Functor f, Functor g, Functor h, f :<: g) 
    => f :<: (h :+: g) where
  -- compare with `lift . lift`
  inj = InR . inj
  prj (InL ha) = Nothing
  prj (InR ga) = prj ga
\end{code}

Within a chain `f :+: g :+: h :+: ...`, there's only ever a single value. We're defining the equivalent of `union`s in other languages, but with some more structure.

\begin{code}
-- called `inject` in the original paper
liftFix :: (g :<: f) => g (Fix f) -> Fix f
liftFix = Fix . inj

-- Val (Fix f) is our base case, since it's a phantom type
val :: Val :<: f => Int -> Fix f
val = liftFix . Val

-- a binary AST node
add :: Add :<: f => Fix f -> Fix f -> Fix f
add l r = liftFix (Add l r)
\end{code}

Now, we can use type classes to implement our effects in a manner that only requires `n` instances. That's a whole order of magnitude less, wew:

\begin{code}
class Functor f => Eval f where
  evalAlg :: f Int -> Int

instance Eval Val where
  evalAlg (Val n) = n

instance Eval Add where
  evalAlg (Add l r) = l + r

instance (Eval f, Eval g) => Eval (f :+: g) where
  evalAlg (InL f) = evalAlg f 
  evalAlg (InR g) = evalAlg g
\end{code}

And now, to fold any arbitrary arithmetic tree:

\begin{code}
evalFix :: Eval f => Fix f -> Int
evalFix = foldExpr evalAlg

ten :: Fix (Add :+: Val)
ten = val 1 `add` val 2 `add` val 3 `add` val 4

-- >>> evalFix ten
-- 10
\end{code}

Yes, this is just [Hutton's Razor](http://www.cs.nott.ac.uk/~pszgmh/exceptions.pdf) with extra steps. A lot of extra steps. But consider a more complicated case where we had more constructors to deal with, and more operations. Adding another constructor would affect every single pattern match site in your code, and lead to a refactoring annoyance, if not a nightmare for larger projects.

In contrast, let's implement multiplication now:

\begin{code}
instance Eval Mul where
  evalAlg (Mul l r) = l * r

mul :: Mul :<: f => Fix f -> Fix f -> Fix f
mul l r = liftFix (Mul l r)

nice :: Fix (Mul :+: Add :+: Val)
nice = (val 24 `add` val 18) `mul` (val 5 `add` val 1 `add` val 4)

-- >>> evalFix nice
-- 420
\end{code}

<hr>

<h2>something something free lunch</h2>

Now that we've written the basis for an extensible, low-boilerplate effects system, it's time to scrap everything and do something cooler.

You might have noticed that `Fix` is just one half of another type that's gotten a lot of attention lately, the `Free` monad:

```haskell
data Free f a
  = Pure a
  | Free (f (Free f a))
  deriving Functor
```

which you can think of as `Fix f` plus a terminating value, solving the problem of types like `Fix Identity` being truly infinite.

I won't go too deeply into free monads since there are [plenty](https://www.tweag.io/blog/2018-02-05-free-monads/) of [resources](https://iohk.io/en/blog/posts/2018/08/07/from-free-algebras-to-free-monads/) [already](http://comonad.com/reader/2008/monads-for-free/) on the topic. The gist of it is that the name `Free` is pretty literal; you get a `Monad` for free from any `Functor`.

```haskell
instance Functor f => Applicative (Free f) where
  pure = Pure
  (<*>) = ap

instance Functor f => Monad (Free f) where
  Pure a >>= f = f a
  Free fa >>= f = Free ((>>= f) <$> fa)
```

This is the traditional representation, and some of its flaws are pretty apparent from the implementation: left-associative `(>>=)`'s require you to traverse down the entire stack, pissing off both the garbage collector and your QA team.

You can use a combination of F-algebras and the `Yoneda` lemma to encode a free monad much more cheaply, given that function composition is cheap as heck (credits to [Edward Kmett's blog](http://comonad.com/reader/2011/free-monads-for-less-2/)):

\begin{code}
-- the spookiest isomorphism in category theory
-- basically a suspended fmap, allowing for traversals of `f` to be delayed until you need them
newtype Yoneda f a = Yoneda {runYoneda :: forall b. (a -> b) -> f b}
  deriving Functor

-- not a Functor, try it for yourself
newtype FAlg f r = FAlg {runFAlg :: (f r -> r) -> r}

newtype Free' f a = Free' (Yoneda (FAlg f) a)
\end{code}

but triply nested newtypes are annoying, so let's expand things into our final representation:

\begin{code}
newtype Free f a = Free 
  { runFree :: forall r. 
    (a -> r) -- extract a pure value
    -> (f r -> r) -- fold f using an F-algebra
    -> r
  }
  deriving Functor

instance Applicative (Free f) where
  pure :: a -> Free f a
  pure x = Free \k _ -> k x

  (<*>) :: forall a b. Free f (a -> b) -> Free f a -> Free f b
  (<*>) = ap
  
instance Monad (Free f) where
  (>>=) :: Free f a -> (a -> Free f b) -> Free f b
  fa >>= f = Free 
    \(br :: b -> any) 
     (frr :: f any -> any) -> 
       runFree fa 
        (\a -> runFree (f a) br frr) 
        frr
\end{code}

By 'flipping' our representation around into one that threads around continuations, we end up with pretty heavy asymptotic improvements over the naive form. Notice that the F-algebra (`f r -> r`, previously the `FAlg f r` component) is untouched, because that argument is the key to how we're going to interpret our free monads later on.

Now that we have a better way of constructing syntax trees, let's look at our previous encoding of type-level unions. Why not improve our ergonomics a bit?

Side note, this document is a Literate Haskell file and I've had to enable like 2000000 extensions by this point. Kindly turn on `GADTs`, `PolyKinds`, `DataKinds`, and `KindSignatures` if you're following along.

```haskell
-- does every type in the list satisfy the constraint?
type ForAll :: (k -> Constraint) -> [k] -> Constraint
type family ForAll cs items where
  ForAll _ '[] = () -- empty constraint
  ForAll cs (item ': items) = (cs item, ForAll cs items) 
```

\ignore{
\begin{code}
class AllSatisfying (cs :: k -> Constraint) (items :: [k]) where
  type ForAll cs items :: Constraint

-- type families keep freezing my HLS, so the actual implementation is just an associated type instead of an open family
instance AllSatisfying cs '[] where
  type ForAll cs '[] = ()

instance AllSatisfying cs items => AllSatisfying cs (item ': items) where
  type ForAll cs (item ': items) = (cs item, ForAll cs items)
\end{code}}

\begin{code}
-- a list of functors and a single inhabitant
data Union (fs :: [Type -> Type]) a where
  -- end of the list
  Here :: f a -> Union '[f] a
  -- either f a, or a union of the list's tail
  There :: (f :+: Union fs) a -> Union (f ': fs) a

deriving instance Functor `ForAll` fs => Functor (Union fs)

\end{code}

\begin{code}
\end{code}

Previously, our instances for finding a subtype `f` within a coproduct `f :+: g` assumed that the coproduct was built right-associatively, that is, `f :+: g :+: h` implies `f :+: (g :+: h)`. Encoding things with a GADT has two advantages: this structure is enforced, and it's easier to type `[Maybe, Either Char, IO, ...]` than `(Maybe :+: Either Char :+: IO :+: ...)`.

Let's define another class for finding `Union` membership too, although we could reuse `(:<:)` for this:

\begin{code}
class Member (f :: Type -> Type) (fs :: [Type -> Type]) where
  inject :: f a -> Union fs a 
  project :: Union fs a -> Maybe (f a)

instance Member f (f ': fs) where
  inject = There . InL

  -- f occurs at the end
  project (Here fa) = Just fa
  -- f occurs at the front, and is inhabited
  project (There (InL fa)) = Just fa
  project _ = Nothing

instance {-# OVERLAPPABLE #-} Member f fs => Member f (g ': fs) where
  inject = There . InR . inject

  project (There (InR fa)) = project fa
  project _ = Nothing
\end{code}

This is a ton of code at this point with no testing, so let's prove that the implementation of `Union` is well-typed:

\begin{code}
someUnion :: Union [Either String, Maybe, IO, Add, Mul] Int
someUnion = inject (Just 1) 
-- There $ InR $ There $ InL (Just 1)

-- Nothing
someIO :: Maybe (IO Int)
someIO = project someUnion

-- Just (Just 1)
someMaybe :: Maybe (Maybe Int)
someMaybe = project someUnion

-- use another union as a witness to help type inference
injectAs :: Member f fs => f a -> Union fs b -> Union fs a
injectAs fs _ = inject fs

injIO, injectEither 
  :: Union '[Either String, Maybe, IO, Add, Mul] Int

injIO = injectAs (read <$> getLine) someUnion
injectEither = injectAs notAnInt someUnion
  where notAnInt = Left @String "lol u errored out"

-- type error: No instance for Member (Either Text) '[]
-- someEitherText :: Maybe (Either Text Int)
-- someEitherText = project someUnion
\end{code}

It might seem inefficient to have to traverse through the same list repeatedly, but we're giving the compiler plenty of info on the exact path of each type within a `Union`, so we don't need to worry too much.

Now it's finally time to put it all together. First, let's build some utils for our effects library:

We're only ever going to use `Free` parameterized over some `Union` of functors, so let's fix our core monad to that type:

\begin{code}
newtype Eff (fs :: [Type -> Type]) a = Eff 
  { runEff :: forall r. 
    (a -> r) 
      -> (Union fs r -> r) 
      -> r
  }
  deriving (Functor, Applicative, Monad) via Free (Union fs)
-- god I love DerivingVia
\end{code}

Now, we need ways to lift and unlift effects as needed:

\begin{code}
-- compare with `lift` from MonadTrans
liftEff ::
  forall f (fs :: [Type -> Type]) a. 
  (Functor f, Member f fs) 
    => f a -> Eff fs a
liftEff fa = Eff 
  \(ar :: a -> r) 
   (frr :: Union fs r -> r) 
     -> frr $ inject (ar <$> fa)

-- we get this for freeeeeeeee
instance Member IO fs => MonadIO (Eff fs) where
  liftIO :: IO a -> Eff fs a
  liftIO = liftEff

-- given a natural transformation on a `Union`
-- (either adding or removing a functor),
-- lift into a new context
hoist :: (forall x. Union fs x -> Union gs x) 
      -> Eff fs a 
      -> Eff gs a
hoist phi fr = Eff \kp kf -> runEff fr kp (kf . phi)

-- Free monads correspond 1:1 to other monads given a natural transformation
foldEff :: Monad m 
  => (forall x. Union fs x -> m x) -> Eff fs a -> m a
foldEff phi fr = runEff fr pure (join . phi)

-- peel off the top effect of an `Eff` stack by handling it in terms of other effects
-- an `Eff` workflow works in terms of incrementally handling effects
interpret 
  :: forall f fs y. (Functor `ForAll` (f ': fs))
  => (forall x. f x -> Eff fs x)
  -> Eff (f ': fs) y 
  -> Eff fs y
interpret phi = foldEff \union -> Eff \kp kf -> 
  let exec fa = runEff (phi fa) kp kf
  in case union of
    Here fa -> exec fa
    There (InL fa) -> exec fa
    There (InR other) -> kf (kp <$> other)

-- we can escape the Eff monad once all effects have been handled
runFinal :: Monad m => Eff '[m] a -> m a
runFinal = foldEff \case 
  Here fx -> fx
  -- compiler can't infer that the list will never be non-empty
  _ -> error "Unreachable"
\end{code}

Congrats, now you have a fully-featured effects system in 200 lines of code. It's **finally** time to try out some effects now, so we'll use the classic `Teletype` example that everyone likes to reach for:

\begin{code}
data Teletype a
  = PrintLn String a
  | GetLine (String -> a)
  deriving Functor

-- the transformation from an Effect type to helper functions is mechanical 
-- and can be abstracted away with TemplateHaskell

println :: Member Teletype fs => String -> Eff fs ()
println s = liftEff (PrintLn s ())

getLine_ :: Member Teletype fs => Eff fs String
getLine_ = liftEff (GetLine id)

\end{code}

And some other effects for posterity, I guess:

\begin{code}
data FileSystem a 
  = ReadFile FilePath (Maybe String -> a)
  | WriteFile FilePath String a
  deriving Functor

readFile_ :: Member FileSystem fs => FilePath -> Eff fs (Maybe String)
readFile_ path = liftEff (ReadFile path id)

writeFile_ :: Member FileSystem fs => FilePath -> String -> Eff fs ()
writeFile_ path s = liftEff (WriteFile path s ())

newtype Error e a = Error e deriving (Functor)

throwErr :: Member (Error e) fs => e -> Eff fs a
throwErr err = liftEff (Error err)
\end{code}

And we'll try seeing these effects in action now:

\begin{code}
interactiveCat 
  :: (Member FileSystem fs, Member Teletype fs, Member (Error String) fs)
  => Eff fs ()
interactiveCat = do
  numFiles <- readMaybe <$> getLine_
  case numFiles of
    Nothing -> throwErr @String 
      "Couldn't parse the number of files you want me to read!!"
    Just n -> replicateM_ n do
      path <- getLine_
      mbFile <- readFile_ path
      body <- maybe (throwErr @String "Couldn't locate file!!") pure mbFile
      traverse_ println (lines body)

ww :: IO ()
ww = interactiveCat
  & interpret interpretFS
  & interpret interpretTTY
  & interpret interpretErr
  & runFinal
  where
    interpretErr :: Error String a -> Eff '[IO] a
    interpretErr = undefined
    interpretFS = \case
      ReadFile path k -> liftIO do
        res <- (Just <$> readFile path) `catch` \(err :: IOException) -> 
          print err $> Nothing
        pure $ k res
      WriteFile path s k -> 
        k <$ liftIO (writeFile path s)
      -- WriteFile path s k -> do
        
    interpretTTY = liftIO . \case
      PrintLn line a -> liftIO (print line) $> a
      GetLine k -> k <$> getLine
\end{code}

todo make interpret polymorphic so we can handle error effects properly
talk about dependency injection/mocking
