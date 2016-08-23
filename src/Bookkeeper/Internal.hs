{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
module Bookkeeper.Internal where

import GHC.OverloadedLabels
import GHC.Generics (Generic)
import qualified Data.Type.Map as Map
import GHC.TypeLits (Symbol)
import Data.Kind (Type)
import Data.Type.Map (Map, Mapping((:->)))
import Data.Coerce
import Data.Proxy

import Bookkeeper.Errors

-- Using a type synonym allows the user to write the fields in any order, and
-- yet have the underlying value always have sorted fields.
type Book a = Book' (Map.AsMap a)
data Book' (a :: [Mapping Symbol Type]) = Book { getBook :: Map a }

emptyBook :: Book '[]
emptyBook = Book Map.Empty

type a :=> b = a ':-> b

instance Monoid (Book' '[]) where
  mempty = emptyBook
  _ `mappend` _ = emptyBook

instance (s ~ s') => IsLabel s (Key s') where
  fromLabel _ = Key

data Key (a :: Symbol) = Key
  deriving (Eq, Show, Read, Generic)

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
get :: forall field book val. (Map.Submap '[field :=> val] book, Contains book field val)
  => Key field -> Book' book -> val
get _ (Book bk) = case (Map.submap bk :: Map '[field :=> val]) of
        Map.Ext _ v Map.Empty -> v

-- | Flipped and infix version of 'get'.
--
-- >>> julian ?: #name
-- "Julian K. Arni"
(?:) :: forall field book val. (Map.Submap '[field :=> val] book, Contains book field val )
  => Book' book -> Key field -> val
(?:) = flip get

-- | Sets or updates a field to a value.
--
-- >>> let julian' = set #likesDoctest True julian
-- >>> get #likesDoctest julian'
-- True
set :: forall field val old mid1 mid2 new .
  ( Map.Unionable '[field :=> ChooseFirst val] mid1
  , Mappable ChooseFirst old mid1
  , Mappable ChooseFirst new mid2
  , mid1 ~ (MapThere ChooseFirst old)
  , mid2 ~ (Map.Union '[field :=> ChooseFirst val] mid1)
  , new ~ MapBack ChooseFirst mid2
  )
  => Key field -> val -> Book' old -> Book' new
set _ v (Book bk)
    = Book $ mapBack p
           $ Map.union new
           $ mapThere p bk
  where
    new = Map.Ext (Map.Var :: Map.Var field) (ChooseFirst v) Map.Empty
    p = Proxy :: Proxy ChooseFirst

-- | Infix version of 'set'
--
-- >>> let julian' = julian & #age =: 29
-- >>> get #age julian'
-- 29
(=:) :: forall field val old mid1 mid2 new .
  ( Map.Unionable '[field :=> ChooseFirst val] mid1
  , Mappable ChooseFirst old mid1
  , Mappable ChooseFirst new mid2
  , mid1 ~ (MapThere ChooseFirst old)
  , mid2 ~ (Map.Union '[field :=> ChooseFirst val] mid1)
  , new ~ MapBack ChooseFirst mid2
  )
  => Key field -> val -> Book' old -> Book' new
(=:) = set


update :: forall field val val' old mid1 mid2 new .
  ( Map.Unionable '[field :=> ChooseFirst val'] mid1
  , Mappable ChooseFirst old mid1
  , Mappable ChooseFirst new mid2
  , (Map.Submap '[field :=> val] old
  , Contains old field val )
  , mid1 ~ (MapThere ChooseFirst old)
  , mid2 ~ (Map.Union '[field :=> ChooseFirst val'] mid1)
  , new ~ MapBack ChooseFirst mid2
  , Map.AsMap new ~ new
  ) =>  Key field -> (val -> val') -> Book' old -> Book new
update p f b = set p v b
  where v = f $ get p b

(%:) :: forall field val val' old mid1 mid2 new .
  ( Map.Unionable '[field :=> ChooseFirst val'] mid1
  , Mappable ChooseFirst old mid1
  , Mappable ChooseFirst new mid2
  , (Map.Submap '[field :=> val] old
  , Contains old field val )
  , mid1 ~ (MapThere ChooseFirst old)
  , mid2 ~ (Map.Union '[field :=> ChooseFirst val'] mid1)
  , new ~ MapBack ChooseFirst mid2
  , Map.AsMap new ~ new
  ) =>  Key field -> (val -> val') -> Book' old -> Book new
(%:) = update


-- * Mapping
--
-- | In order to be able to establish how maps are to combined, we need to a
-- little song and dance.

type family MapThere (f :: Type -> Type) (map :: [Mapping Symbol Type])  where
  MapThere f '[] = '[]
  MapThere f ((k :=> a) ': as) = (k :=> f a) ': MapThere f as

type family MapBack f (map :: [Mapping Symbol Type]) where
  MapBack f '[] = '[]
  MapBack f ((k :=> f a) ': as) =  k :=> a ': MapBack f as

class (MapThere f a ~ b, MapBack f b ~ a ) => Mappable f a b | f a -> b, f b -> a where
  mapThere :: proxy f -> Map a -> Map b
  mapBack :: proxy f -> Map b -> Map a

instance Mappable f '[] '[] where
  mapThere _ x = x
  mapBack _  x = x

instance (Coercible a (f a), Coercible (f a) a, Mappable f as fas )
  => Mappable f ((k :=> a) ': as) ((k :=> f a) ': fas) where
  mapThere p (Map.Ext v k r) = Map.Ext v (coerce k) $ mapThere p r
  mapBack p (Map.Ext v k r) = Map.Ext v (coerce k) $ mapBack p r


class MapMap f map where
  type MapMapT f map :: [Mapping Symbol Type]
  mapMap :: f -> Map map -> Map (MapMapT f map)


instance MapMap f '[] where
  type MapMapT f '[] = '[]
  mapMap _ m = m

newtype ChooseFirst a = ChooseFirst { getChooseFirst :: a }
 deriving (Eq, Show, Read, Generic)

instance Map.Combinable (ChooseFirst a) (ChooseFirst b) where
  combine a _ = a

type instance Map.Combine (ChooseFirst a) (ChooseFirst b) = ChooseFirst a


-- $setup
-- >>> import Data.Function ((&))
-- >>> type Person = Book '[ "name" :=> String , "age" :=> Int ]
-- >>> let julian :: Person = emptyBook & #age =: 28 & #name =: "Julian K. Arni"