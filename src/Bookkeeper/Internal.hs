{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
module Bookkeeper.Internal where

import GHC.OverloadedLabels
import GHC.Generics
import qualified Data.Type.Map as Map
import GHC.TypeLits (Symbol, KnownSymbol, TypeError, ErrorMessage(..))
import Data.Default.Class (Default(..))
import Data.Kind (Type)
import Data.Type.Map (Map, Mapping((:->)))
import Data.Monoid ((<>))
import Data.List (intercalate)

import Bookkeeper.Internal.Errors

------------------------------------------------------------------------------
-- Book
------------------------------------------------------------------------------

-- Using a type synonym allows the user to write the fields in any order, and
-- yet have the underlying value always have sorted fields.
type Book a = Book' (Map.AsMap a)

-- | The internal representation of a Book.
newtype Book' (a :: [Mapping Symbol Type]) = Book { getBook :: Map a }

instance ShowHelper (Book' a) => Show (Book' a) where
  show x = "Book {" <> intercalate ", " (go <$> showHelper x) <> "}"
    where
      go (k, v) = k <> " = " <> v

class ShowHelper a where
  showHelper :: a -> [(String, String)]

instance ShowHelper (Book' '[]) where
  showHelper _ = []

instance ( ShowHelper (Book' xs)
         , KnownSymbol k
         , Show v
         ) => ShowHelper (Book' ((k :=> v) ': xs)) where
  showHelper (Book (Map.Ext k v rest)) = (show k, show v):showHelper (Book rest)

instance Eq (Map.Map xs) => Eq (Book' xs) where
  Book x == Book y = x == y

instance Ord (Map.Map xs) => Ord (Book' xs) where
  compare (Book x) (Book y) = compare x y

instance Monoid (Book' '[]) where
  mempty = emptyBook
  _ `mappend` _ = emptyBook

instance Default (Book' '[]) where
  def = emptyBook

instance ( Default (Book' xs)
         , Default v
         ) => Default (Book' ((k :=> v) ': xs)) where
  def = Book (Map.Ext Map.Var def (getBook def))

-- | A book with no records. You'll usually want to use this to construct
-- books.
emptyBook :: Book '[]
emptyBook = Book Map.Empty

------------------------------------------------------------------------------
-- Other types
------------------------------------------------------------------------------

-- | An alias for ':->' because otherwise you'll have to tick your
-- constructors.
type a :=> b = a ':-> b


instance (s ~ s') => IsLabel s (Key s') where
#if MIN_VERSION_base(4,10,0)
  fromLabel = Key
#else
  fromLabel _ = Key
#endif

-- | 'Key' is simply a proxy. You will usually not need to generate it
-- directly, as it is generated by the OverlodadedLabels magic.
data Key (a :: Symbol) = Key
  deriving (Eq, Show, Read, Generic)

------------------------------------------------------------------------------
-- Setters and getters
------------------------------------------------------------------------------

-- * Getters

-- | @Gettable field val book@ is the constraint needed to get a value of type
-- @val@ from the field @field@ in the book of type @Book book@.
type Gettable field book val = (Map.Submap '[field :=> val] book, Contains book field val)

-- | Get a value by key, if it exists.
--
-- >>> get #age julian
-- 28
--
-- If the key does not exist, throws a type error
-- >>> get #moneyFrom julian
-- ...
-- ...  • The provided Book does not contain the field "moneyFrom"
-- ...    Book type:
-- ...    '["age" ':-> Int, "name" ':-> String]
-- ...  • In the expression: get #moneyFrom julian
-- ...
get :: forall field book val. (Gettable field book val)
  => Key field -> Book' book -> val
get _ (Book bk) = case (Map.submap bk :: Map '[field :=> val]) of
        Map.Ext _ v Map.Empty -> v

-- | Flipped and infix version of 'get'.
--
-- >>> julian ?: #name
-- "Julian K. Arni"
(?:) :: forall field book val. (Gettable field book val)
  => Book' book -> Key field -> val
(?:) = flip get
infixl 3 ?:

-- * Setters

-- | 'Settable field val old new' is a constraint needed to set the the field
-- 'field' to a value of type 'val' in the book of type 'Book old'. The
-- resulting book will have type 'Book new'.
type Settable field val old new =
  (
    Map.Submap (Map.AsMap (old Map.:\ field)) old
  , Map.Unionable '[ field :=> val] (Map.AsMap (old Map.:\ field))
  , new ~ Map.AsMap (( field :=> val) ': (Map.AsMap (old Map.:\ field)))
  )

-- | Sets or updates a field to a value.
--
-- >>> set #likesDoctest True julian
-- Book {age = 28, likesDoctest = True, name = "Julian K. Arni"}
set :: forall field val old new .  ( Settable field val old new)
  => Key field -> val -> Book' old -> Book' new
set p v old = Book new
  where
    Book deleted = delete p old
    added = Map.Ext (Map.Var :: Map.Var field) v deleted
    new = Map.asMap added

-- | Infix version of 'set'
--
-- >>> julian & #age =: 29
-- Book {age = 29, name = "Julian K. Arni"}
(=:) :: ( Settable field val old new)
  => Key field -> val -> Book' old -> Book' new
(=:) = set
infix 3 =:

-- * Modifiers

-- | @Modifiable field val val' old new@ is a constraint needed to apply a
-- function of type @val -> val'@ to the field @field@ in the book of type
-- @Book old@. The resulting book will have type @Book new@.
type Modifiable field val val' old new =
  ( Settable field val' old new
  , Map.AsMap new ~ new
  , Contains old field val
  , Map.Submap '[ field :=> val] old
  )

-- | Apply a function to a field.
--
-- >>> julian & modify #name (fmap toUpper)
-- Book {age = 28, name = "JULIAN K. ARNI"}
--
-- If the key does not exist, throws a type error
-- >>> modify #height (\_ -> 132) julian
-- ...
-- ...  • The provided Book does not contain the field "height"
-- ...    Book type:
-- ...    '["age" ':-> Int, "name" ':-> String]
-- ...  • In the expression: modify #height (\ _ -> 132) julian
-- ...
modify :: ( Modifiable field val val' old new)
  =>  Key field -> (val -> val') -> Book' old -> Book new
modify p f b = set p v b
  where v = f $ get p b

-- | Infix version of 'modify'.
--
-- >>> julian & #name %: fmap toUpper
-- Book {age = 28, name = "JULIAN K. ARNI"}
(%:) :: ( Modifiable field val val' old new)
  => Key field -> (val -> val') -> Book' old -> Book new
(%:) = modify
infixr 3 %:


-- | Delete a field from a 'Book', if it exists. If it does not, returns the
-- @Book@ unmodified.
--
-- >>> get #name $ delete #name julian
-- ...
-- ...  • The provided Book does not contain the field "name"
-- ...    Book type:
-- ...    '["age" ':-> Int]
-- ...  • In the expression: get #name
-- ...
delete :: forall field old .
        ( Map.Submap (Map.AsMap (old Map.:\ field)) old
        ) => Key field -> Book' old -> Book (old Map.:\ field)
delete _ (Book bk) = Book $ Map.submap bk

-- * Generics

class FromGeneric a book | a -> book where
  fromGeneric :: a x -> Book' book

instance FromGeneric cs book => FromGeneric (D1 m cs) book where
  fromGeneric (M1 xs) = fromGeneric xs

instance FromGeneric cs book => FromGeneric (C1 m cs) book where
  fromGeneric (M1 xs) = fromGeneric xs

instance (v ~ Map.AsMap ('[name ':-> t]))
  => FromGeneric (S1 ('MetaSel ('Just name) p s l) (Rec0 t)) v where
  fromGeneric (M1 (K1 t)) = (Key =: t) emptyBook

instance
  ( FromGeneric l lbook
  , FromGeneric r rbook
  , Map.Unionable lbook rbook
  , book ~ Map.Union lbook rbook
  ) => FromGeneric (l :*: r) book where
  fromGeneric (l :*: r)
    = Book $ Map.union (getBook (fromGeneric l)) (getBook (fromGeneric r))

type family Expected a where
  Expected (l :+: r) = TypeError ('Text "Cannot convert sum types into Books")
  Expected U1        = TypeError ('Text "Cannot convert non-record types into Books")

instance (book ~ Expected (l :+: r)) => FromGeneric (l :+: r) book where
  fromGeneric = error "impossible"

instance {-# OVERLAPPABLE #-}
  (book ~ Expected lhs, lhs ~ U1
  ) => FromGeneric lhs book where
  fromGeneric = error "impossible"


-- | Generate a @Book@ from an ordinary Haskell record via GHC Generics.
--
-- >>> data Test = Test {  field1 :: String, field2 :: Int, field3 :: Char } deriving Generic
-- >>> fromRecord (Test "hello" 0 'c')
-- Book {field1 = "hello", field2 = 0, field3 = 'c'}
--
-- Trying to convert a datatype which is not a record will result in a type
-- error:
--
-- >>> data SomeSumType = LeftSide | RightSide deriving Generic
-- >>> fromRecord LeftSide
-- ...
-- ... • Cannot convert sum types into Books
-- ...
--
-- >>> data Unit = Unit deriving Generic
-- >>> fromRecord Unit
-- ...
-- ... • Cannot convert non-record types into Books
-- ...
fromRecord :: (Generic a, FromGeneric (Rep a) bookRep) => a -> Book' bookRep
fromRecord = fromGeneric . from

-- $setup
-- >>> import Data.Function ((&))
-- >>> import Data.Char (toUpper)
-- >>> type Person = Book '[ "name" :=> String , "age" :=> Int ]
-- >>> let julian :: Person = emptyBook & #age =: 28 & #name =: "Julian K. Arni"
