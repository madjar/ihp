{-# LANGUAGE FunctionalDependencies, AllowAmbiguousTypes, UndecidableInstances, TypeOperators, TypeFamilyDependencies #-}
module Foundation.RouterSupport (
    (:>)(..)
    , CanRoute (..)
    , HasPath (..)
    , RestfulController (..)
    , runAction
    , get
    , post
    , prepareWAIApp
    , RestfulControllerId
    , withPrefix
    , parseUUID
    , parsePathArgument
    , isIndexAction
    , isShowAction
    , isCreateAction
    , isUpdateAction
    , isDeleteAction
    , isEditAction
    , modelId
    , Child
    , PathArgument (..)
) where

import ClassyPrelude hiding (index, delete, take)
import qualified Foundation.ModelSupport as ModelSupport
import Foundation.ApplicationContext
import Data.UUID
import           Network.HTTP.Types.Method
import GHC.Records
import Foundation.Controller.RequestContext
import Network.Wai
import Control.Lens hiding (index, (:>), Context)
import Data.Generics.Product hiding (getField)
import Data.String.Conversions (cs)
import Data.Proxy
import Foundation.ControllerSupport
import Data.Attoparsec.Char8 (string, Parser, (<?>), parseOnly, take, endOfInput, choice, takeTill)
import Data.Typeable (typeRep)
import GHC.Generics
import GHC.TypeLits
import Data.Data
import Foundation.NameSupport
import qualified Data.UUID as UUID
import Data.Default

import Data.Generics.Product hiding (getField)
import Data.Maybe (fromJust)
import qualified Control.Newtype.Generics as Newtype

type family Parent controller where
    Parent (parent :> child) = parent
    Parent parent = parent

type family Child controller where
    Child (parent :> child) = child
    Child child = child

data (parent :> child) = parent :> child deriving (Generic, Eq, Data, Show)


class HasPath controller where
    pathTo :: controller -> Text    

class HasPath controller => CanRoute controller parent | controller -> parent where
    parseRoute :: (?applicationContext :: ApplicationContext, ?requestContext :: RequestContext) => Parser (IO ResponseReceived)
    parseRoute' :: (?applicationContext :: ApplicationContext, ?requestContext :: RequestContext) => Parser controller

parseUUID :: Parser UUID
parseUUID = do
        uuid <- take 36
        case fromASCIIBytes uuid of 
            Just theUUID -> return $! theUUID
            Nothing -> fail "not uuid"

type family RestfulControllerId controller where
    RestfulControllerId (parent :> child) = RestfulControllerId child
    RestfulControllerId controller = HeadOrDefault (RestfulControllerId' (Rep controller)) ()

type family RestfulControllerId' (x :: * -> *) where
    RestfulControllerId' (D1 _d d) = RestfulControllerId' d
    RestfulControllerId' (C1 _c c) = RestfulControllerId' c
    RestfulControllerId' (a :+: b) = Concat (RestfulControllerId' a) (RestfulControllerId' b)
    -- RestfulControllerId' (x :+: (C1 _c U1)) = RestfulControllerId' x
    --RestfulControllerId' ((C1 _c c) :+: b) = RestfulControllerId' c
    -- RestfulControllerId' (a :*: b) = 
    RestfulControllerId' (S1 _s (K1 _i b)) = '[b]
    RestfulControllerId' U1 = '[]
    -- (C1 _c (S1 _s (K1 _i b)))

type family HeadOrDefault x d where
    HeadOrDefault (x ': xs) d = x
    HeadOrDefault otherwise d = d

type family Concat a b where
    Concat a '[] = a
    Concat a (x ': xs) = Concat (x ': a) xs


{-# INLINE getConstructorByName #-}
getConstructorByName :: forall theType. Data theType => String -> Maybe Constr
getConstructorByName name = readConstr (dataTypeOf (ClassyPrelude.undefined :: theType)) name

{-# INLINE constructorWithId #-}
constructorWithId :: forall controller. (RestfulController controller, Data (Child controller), Data (RestfulControllerId controller)) => Text -> Maybe (RestfulControllerId controller -> Child controller)
constructorWithId name =
    case getConstructorByName @(Child controller) (cs (name <> (pluralToSingular $ cs (basePath @controller)) <> "Action")) of
        Just constructor -> Just (\id -> fromJust $ fromConstrM (cast id :: forall d. Data d => Maybe d) constructor)
        Nothing -> Nothing

class (Typeable controller, Generic controller, Data controller, Data (Child controller), Data (RestfulControllerId controller)) => RestfulController controller where
    {-# INLINE basePath #-}
    basePath :: ByteString
    basePath =
        let controllerName = cs . tshow $ typeRep (Proxy :: Proxy (Child controller))
        in controllerNameToPathName controllerName
    indexAction :: Maybe (Child controller)
    indexAction = fromConstr <$> getConstructorByName @(Child controller) (cs (basePath @controller <> "Action"))
    newAction :: Maybe (Child controller)
    newAction = fromConstr <$> getConstructorByName @(Child controller) (cs ("New" <> (pluralToSingular $ cs (basePath @controller)) <> "Action"))
    createAction :: Maybe (Child controller)
    createAction = fromConstr <$> getConstructorByName @(Child controller) (cs ("Create" <> (pluralToSingular $ cs (basePath @controller)) <> "Action"))
    showAction :: Maybe (RestfulControllerId controller -> Child controller)
    showAction = constructorWithId @controller "Show"
    editAction :: Maybe (RestfulControllerId controller -> Child controller)
    editAction = constructorWithId @controller "Edit"
    updateAction :: Maybe (RestfulControllerId controller -> Child controller)
    updateAction = constructorWithId @controller "Update"
    deleteAction :: Maybe (RestfulControllerId controller -> Child controller)
    deleteAction = constructorWithId @controller "Delete"
    customActions :: (?applicationContext :: ApplicationContext, ?requestContext :: RequestContext, HasTypes (Child controller) (RestfulControllerId controller)) => (Child controller) -> Parser controller
    customActions idContainer =
        let
            id = modelId @controller idContainer
            allConstructors = dataTypeConstrs (dataTypeOf (ClassyPrelude.undefined :: Child controller))
            customConstructors = filter (not . isRestConstructor) allConstructors
            isRestConstructor constructor = (showConstr constructor) `elem` restConstructorNames
            restConstructorNames =
                    [ cs (basePath @controller <> "Action")
                    , cs ("New" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    , cs ("Create" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    , cs ("Show" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    , cs ("Edit" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    , cs ("Update" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    , cs ("Delete" <> (pluralToSingular $ cs (basePath @controller)) <> "Action")
                    ]
            parseCustomAction action' = (string actionPath >> post action)
                where
                    action = initiateAction action' id
                    initiateAction constructor id = fromJust $ fromConstrM (cast id :: forall d. Data d => Maybe d) constructor
                    actionName = showConstr action'
                    withoutActionSuffix = fromMaybe actionName (stripSuffix "Action" actionName)
                    modelName = cs $ pluralToSingular $ cs (basePath @controller)
                    withoutModelPrefix = fromMaybe withoutActionSuffix (stripPrefix modelName withoutActionSuffix)
                    actionPath = cs withoutModelPrefix
        in choice (map parseCustomAction customConstructors)
            

-- controllerNameToPathName "XController" = "X"
controllerNameToPathName :: ByteString -> ByteString
controllerNameToPathName controllerName = fromMaybe controllerName (stripSuffix "Controller" controllerName)

class PathArgument a where
    parsePathArgument :: Parser a

instance PathArgument () where
    parsePathArgument = string "current" >> return ()

instance PathArgument (ModelSupport.Id' (model :: Symbol)) where
    parsePathArgument = parseUUID >>= return . Newtype.pack

instance PathArgument Text where
    parsePathArgument = takeTill ((==) '/') >>= return . cs


instance {-# OVERLAPPABLE #-} forall id controller parent child context. (Eq controller, Generic controller, Show id, Show controller, PathArgument id, RestfulController controller, RestfulControllerId controller ~ id, Controller controller context, parent ~ (), Child controller ~ controller, HasTypes controller id, Default id) => CanRoute controller parent where
    --pathTo action | action == indexAction = "/Members"
    --pathTo action | action == newAction = pathTo (indexAction @controller) <> "/new"
    --pathTo action | action == createAction = pathTo (indexAction @controller)
    --pathTo action = error "TODO"
        --let id = unsafeHead (toListOf (types @id) action)
        --in pathTo (showAction @controller id) <> "/" <> tshow id <> (if editAction id == action then "/edit" else "")
    parseRoute = parseRoute' @controller >>= return . runAction
    parseRoute' =
        let
            indexAction' = fromJust (indexAction @controller)
            newAction' = fromJust (newAction @controller)
            createAction' = fromJust (createAction @controller)
            showAction' :: RestfulControllerId controller -> Child controller
            showAction' memberId = fromJust (showAction @controller) $ memberId
            updateAction' :: RestfulControllerId controller -> Child controller
            updateAction' memberId = fromJust (updateAction @controller) $ memberId
            deleteAction' :: RestfulControllerId controller -> Child controller
            deleteAction' memberId = fromJust (deleteAction @controller) $ memberId
            editAction' :: RestfulControllerId controller -> Child controller
            editAction' memberId = fromJust (editAction @controller) $ memberId
        in (string (basePath @controller)) >> (
            string "/" >> (string "new" >> get (newAction'))
                <|> (do
                    memberId <- parsePathArgument
                    (string "/" >> ((string "edit" >> get (editAction' memberId)) <|> (customActions ((showAction' memberId)) >>= return ) ))
                        <|> (onGetOrPostOrDelete (showAction' memberId) (updateAction' memberId) (deleteAction' memberId))
                )
            )
            <|> onGetOrPost (indexAction') (createAction')


instance {-# OVERLAPPABLE #-} forall id controller parent child. (Eq controller, Eq child, Generic controller, Show id, PathArgument id, RestfulController controller, RestfulControllerId controller ~ id, parent ~ Parent controller, controller ~ (parent :> Child controller), child ~ Child controller, HasPath parent, HasTypes child id, Child child ~ child, Show child, Show controller, Default id) => HasPath (parent :> child) where
    pathTo (parent :> child) = pathTo parent <> genericPathTo @controller child




instance {-# OVERLAPPABLE #-} forall id controller parent child. (Eq controller, Generic controller, Show id, Show controller, PathArgument id, RestfulController controller, RestfulControllerId controller ~ id, Child controller ~ controller, HasTypes controller id, Default id) => HasPath controller where
    pathTo = genericPathTo @controller

genericPathTo :: forall controller action id parent. (Eq action, Generic controller, Show id, Show controller, PathArgument id, RestfulController controller, RestfulControllerId controller ~ id, HasTypes action id, RestfulController controller, Child controller ~ action, Default id) => action -> Text
genericPathTo action 
    | (isIndexAction @controller action) || (isCreateAction @controller action)
        = "/" <> cs (basePath @controller)
    | isNewAction @controller action
        = genericPathTo @controller (fromJust $ indexAction @controller) <> "/new"
    | isEditAction @controller action
        = let id = unsafeHead (toListOf (types @id) action)
        in genericPathTo @controller (fromJust (showAction @controller) $ id) <> "/edit"
    | (isShowAction @controller action) || (isDeleteAction @controller action) || (isUpdateAction @controller action)
        = let id = unsafeHead (toListOf (types @id) action) in genericPathTo @controller (fromJust $ indexAction @controller) <> "/" <> tshow id
    | otherwise =
        let
            id = unsafeHead (toListOf (types @id) action)
            actionName = showConstr (toConstr action)
            withoutActionSuffix = fromMaybe actionName (stripSuffix "Action" actionName)
            modelName = cs $ pluralToSingular $ cs (basePath @controller)
            withoutModelPrefix = fromMaybe withoutActionSuffix (stripPrefix modelName withoutActionSuffix)
        in
            genericPathTo @controller (fromJust $ indexAction @controller) <> "/" <> tshow id <> "/" <> (cs $ controllerNameToPathName (cs withoutModelPrefix))

{-# INLINE isIndexAction #-}
isIndexAction :: forall controller. (RestfulController controller, Eq (Child controller)) => Child controller -> Bool
isIndexAction action = (isJust (indexAction @controller) && action == fromJust (indexAction @controller))

{-# INLINE isCreateAction #-}
isCreateAction :: forall controller. (RestfulController controller, Eq (Child controller)) => Child controller -> Bool
isCreateAction action = (isJust (createAction @controller) && action == fromJust (createAction @controller))

{-# INLINE isNewAction #-}
isNewAction :: forall controller. (RestfulController controller, Eq (Child controller)) => Child controller -> Bool
isNewAction action = (isJust (newAction @controller) && action == fromJust (newAction @controller))

{-# INLINE isEditAction #-}
isEditAction :: forall controller. (RestfulController controller, Eq (Child controller), Default (RestfulControllerId controller)) => Child controller -> Bool
isEditAction action = (isJust (editAction @controller) && toConstr action == toConstr (fromJust (editAction @controller) $ def))

{-# INLINE isShowAction #-}
isShowAction :: forall controller. (RestfulController controller, Eq (Child controller), Default (RestfulControllerId controller)) => Child controller -> Bool
isShowAction action = (isJust (showAction @controller) && toConstr action == toConstr (fromJust (showAction @controller) $ def))

{-# INLINE isDeleteAction #-}
isDeleteAction :: forall controller. (RestfulController controller, Eq (Child controller), Default (RestfulControllerId controller)) => Child controller -> Bool
isDeleteAction action = (isJust (deleteAction @controller) && toConstr action == toConstr (fromJust (deleteAction @controller) $ def))

{-# INLINE isUpdateAction #-}
isUpdateAction :: forall controller. (RestfulController controller, Eq (Child controller), Default (RestfulControllerId controller)) => Child controller -> Bool
isUpdateAction action = (isJust (updateAction @controller) && toConstr action == toConstr (fromJust (updateAction @controller) $ def))

{-# INLINE modelId #-}
modelId :: forall controller. (RestfulController controller, HasTypes (Child controller) (RestfulControllerId controller)) => Child controller -> RestfulControllerId controller
modelId action = unsafeHead (toListOf (types @(RestfulControllerId controller)) action)

instance {-# OVERLAPPABLE #-} forall id controller parent child parentParent context. (Eq controller, Eq child, Generic controller, Show id, PathArgument id, RestfulController controller, RestfulControllerId controller ~ id, Controller controller context, parent ~ Parent controller, controller ~ (parent :> Child controller), child ~ Child controller, HasPath parent, HasTypes child id, Child child ~ child, Show child, Show controller, CanRoute parent parentParent, Default id) => CanRoute (parent :> child) parent where
    --pathTo action | action == indexAction = "/Members"
    --pathTo action | action == newAction = pathTo (indexAction @controller) <> "/new"
    --pathTo action | action == createAction = pathTo (indexAction @controller)
    --pathTo action = error "TODO"
        --let id = unsafeHead (toListOf (types @id) action)
        --in pathTo (showAction @controller id) <> "/" <> tshow id <> (if editAction id == action then "/edit" else "")
    parseRoute = parseRoute' @controller >>= return . runAction
    parseRoute' = do
        parent <- parseRoute' @parent
        string "/"
        let
            indexAction' = parent :> (fromJust $ indexAction @controller)
            newAction' = parent :> (fromJust $ newAction @controller)
            createAction' = parent :> (fromJust $ createAction @controller)
            showActionWithoutParent memberId = (fromJust (showAction @controller) $ memberId)
            showAction' memberId = parent :> showActionWithoutParent memberId
            updateAction' memberId = parent :> (fromJust (updateAction @controller) $ memberId )
            deleteAction' memberId = parent :> (fromJust (deleteAction @controller) $ memberId )
            editAction' memberId = parent :> (fromJust (editAction @controller) $ memberId )
        (string (basePath @controller)) >> (
            string "/" >> (string "new" >> get (newAction'))
                <|> (do
                    memberId <- parsePathArgument
                    (string "/" >> ((string "edit" >> get (editAction' memberId)) <|> (customActions (showActionWithoutParent memberId) >>= return ) ))
                        <|> (onGetOrPostOrDelete (showAction' memberId) (updateAction' memberId) (deleteAction' memberId))
                )
            )
            <|> onGetOrPost indexAction' createAction'


{-# INLINE getMethod #-}
getMethod :: (?requestContext :: RequestContext) => Parser StdMethod
getMethod = 
    let methodOrError = parseMethod (requestMethod (Foundation.Controller.RequestContext.request ?requestContext))
    in
        case methodOrError of
            Left error -> fail (cs error)
            Right method -> return method

{-# INLINE post #-}
post action = do
    method <- getMethod
    case method of 
        POST -> return action
        _   -> fail "Invalid method, expected POST"

{-# INLINE get #-}
get action = do
    method <- getMethod
    case method of 
        GET -> return action
        _   -> fail "Invalid method, expected GET"

{-# INLINE onGetOrPost #-}
onGetOrPost getResult postResult = do
    method <- getMethod
    (case method of
                    GET  -> return getResult
                    POST -> return postResult
                    _    -> fail "Invalid method, expected GET or POST"
                )

{-# INLINE onGetOrPostOrDelete #-}
onGetOrPostOrDelete getResult postResult deleteResult = do
    method <- getMethod
    case method of
        GET    -> return getResult
        POST   -> return postResult
        DELETE -> return deleteResult
        _      -> fail "Invalid method, expected GET, POST or DELETE"



{-# INLINE withPrefix #-}
withPrefix prefix routes = string prefix >> choice (map (\r -> r <* endOfInput) routes)

{-# INLINE runApp #-}
runApp :: (?applicationContext :: ApplicationContext, ?requestContext :: RequestContext) => Parser (IO ResponseReceived) -> IO ResponseReceived
runApp routes = let path = (rawPathInfo (getField @"request" ?requestContext)) in case parseOnly (routes <* endOfInput) path of
            Left message -> error ("Failed to route `" <> cs path <> "`: " <> message)
            Right action -> action

{-# INLINE prepareWAIApp #-}
prepareWAIApp :: forall app parent config. (Eq app, parent ~ (), CanRoute app parent, ?applicationContext :: ApplicationContext, ?requestContext :: RequestContext) => IO ResponseReceived
prepareWAIApp = runApp (parseRoute @app)