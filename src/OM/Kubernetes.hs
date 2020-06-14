{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

{- | Kubernetes interface utilities. -}
module OM.Kubernetes (
  -- * Creating a handle
  newK8s,
  K8s,

  -- * Operations
  listPods,
  postPod,
  deletePod,
  getPodSpec,
  patchService,
  getServiceSpec,
  postService,

  -- * Types
  JsonPatch(..),
  PodName(..),
  PodSpec(..),
  PodList(..),
  ServiceName(..),
  ServiceSpec(..),
) where


import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson ((.:), FromJSON, FromJSONKey, ToJSON, ToJSONKey, Value,
  encode, parseJSON, withObject)
import Data.Default.Class (def)
import Data.Proxy (Proxy(Proxy))
import Data.String (IsString, fromString)
import Data.Text (Text)
import Data.X509.CertificateStore (CertificateStore, readCertificateStore)
import Network.Connection (TLSSettings(TLSSettings))
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.TLS (clientShared, clientSupported,
  clientUseServerNameIndication, defaultParamsClient, sharedCAStore,
  supportedCiphers)
import Network.TLS.Extra.Cipher (ciphersuite_default)
import OM.HTTP (BearerToken(BearerToken), AllTypes)
import Servant.API ((:<|>)((:<|>)), NoContent(NoContent), (:>), Accept,
  Capture, DeleteNoContent, Description, Get, Header', JSON, MimeRender,
  PatchNoContent, PostNoContent, QueryParam, ReqBody, Required, Strict,
  contentType, mimeRender)
import Servant.API.Flatten (flatten)
import Servant.Client (BaseUrl(BaseUrl), Scheme(Https), ClientEnv,
  ClientM, client, mkClientEnv, runClientM)
import System.Environment (getEnv)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Text.IO as TIO


{- | A handle on the kubernetes service. -}
data K8s = K8s {
       kNamespace :: Namespace,
         kManager :: Manager
                     {- ^
                       An http client manager configured to work against
                       the kubernetes api.
                     -}
  }


{- |
  Create a new 'K8s'. The handle will contain an implicit reference
  to the current namespace, and all operations will be within that
  namespace. There is no way to break out into a different namespace.
-}
newK8s
  :: ( MonadIO m
     )
  => m K8s
newK8s = liftIO $ do
    namespace <- fromString <$> getEnv "OM_KUBERNETES_NAMESPACE"
    readCertificateStore crtLocation >>= \case
      Nothing -> fail "Can't load K8S CA certificate."
      Just store -> do
        manager <-
          newManager
               (
                 mkManagerSettings
                   (k8sTLSSettings store)
                   Nothing
               )
        pure K8s {
               kNamespace = namespace,
                 kManager = manager
          }
  where
    k8sTLSSettings :: CertificateStore -> TLSSettings
    k8sTLSSettings store =
      TLSSettings $
        (defaultParamsClient mempty mempty) {
          clientShared = def {
            sharedCAStore = store
          },
          clientSupported = def {
            supportedCiphers = ciphersuite_default
          },
          clientUseServerNameIndication = True
        }
    crtLocation :: FilePath
    crtLocation = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


{- | A subset of the kubernetes api spec. -}
type KubernetesApi = 
  Description "Kubernetes api"
    :> Header' [Required, Strict] "Authorization" BearerToken
    :> (
      Description "Pods API"
        :> "api"
        :> "v1"
        :> "namespaces"
        :> Capture "namespace" Namespace
        :> "pods"
        :> PodsApi

      :<|> Description "Services API."
        :> "api"
        :> "v1"
        :> "namespaces"
        :> Capture "namespace" Namespace
        :> "services"
        :> ServicesApi
    )


{- | A subset of the kubernetes api spec related to services. -}
type ServicesApi =
    Description "Get the cluster service."
    :> Capture "service-name" ServiceName
    :> Get '[JSON] ServiceSpec
  :<|>
    Description "Post a new serivce."
    :> ReqBody '[JSON] ServiceSpec
    :> PostNoContent '[AllTypes] NoContent
  :<|>
    Description "Update the cluster spec annotation."
    :> Capture "service-name" ServiceName
    :> ReqBody '[JsonPatch] JsonPatch
    :> PatchNoContent '[AllTypes] NoContent


{- | Specify how to patch the pod template spec. -}
newtype JsonPatch = JsonPatch {
    unJsonPatch :: Value
  }
  deriving newtype (ToJSON)
instance Accept JsonPatch where
  contentType _proxy = "application/json-patch+json"
instance MimeRender JsonPatch JsonPatch where
 mimeRender _ = encode


{- | A subset of the kubernetes api spec related to pods. -}
type PodsApi =
    Description "List pods"
    :> Get '[JSON] PodList
  :<|>
    Description "Post a pod definition"
    :> ReqBody '[JSON] PodSpec
    :> PostNoContent '[AllTypes] NoContent
  :<|>
    Description "Delete a pod"
    :> Capture "pod-name" PodName
    :> DeleteNoContent '[AllTypes] NoContent
  :<|>
    Description "Get a pod spec"
    :> Capture "pod-name" PodName
    :> QueryParam "export" Bool
    :> Get '[JSON] PodSpec



{- | A list of pods. -}
newtype PodList = PodList {
    unPodList :: [PodName]
  }
instance FromJSON PodList where
  parseJSON = withObject "Pod List" $ \o -> do
    list <- o .: "items"
    PodList <$> mapM ((.: "metadata") >=> (.: "name")) list


{- ==================================== List all pods ======================= -}
{- | Get the list of pods. -}
kListPods :: BearerToken -> Namespace -> ClientM PodList

{- | List the pods. -}
listPods :: (MonadIO m) => K8s -> m PodList
listPods k = do
  token <- getServiceAccountToken
  let req = kListPods token (kNamespace k)
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right list -> pure list


{- ==================================== Post a new pod ====================== -}
{- | Create a new pod. -}
kPostPod :: BearerToken -> Namespace -> PodSpec -> ClientM NoContent

{- | Create a new pod. -}
postPod :: (MonadIO m) => K8s -> PodSpec -> m ()
postPod k spec = do
  token <- getServiceAccountToken
  let req = kPostPod token (kNamespace k) spec
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- ==================================== Delete a pod ======================== -}
{- | Delete a pod. -}
kDeletePod :: BearerToken -> Namespace -> PodName -> ClientM NoContent

{- | Delete a pod. -}
deletePod :: (MonadIO m) => K8s -> PodName -> m ()
deletePod k podName = do
  token <- getServiceAccountToken
  let req = kDeletePod token (kNamespace k) podName
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()
  

{- ==================================== Delete a pod ======================== -}
{- | Get the spec of a specific pod. -}
kGetPodSpec :: BearerToken -> Namespace -> PodName -> ClientM PodSpec

{- | Get the spec of a specific pod. -}
getPodSpec :: (MonadIO m) => K8s -> PodName -> m PodSpec
getPodSpec k podName = do
  token <- getServiceAccountToken
  let req = kGetPodSpec token (kNamespace k) podName
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right spec -> pure spec
  

{- ==================================== Patch a service ===================== -}
{- | Patch a service. -}
kPatchService
  :: BearerToken
  -> Namespace
  -> ServiceName
  -> JsonPatch
  -> ClientM NoContent

{- | Patch a service. -}
patchService :: (MonadIO m) => K8s -> ServiceName -> JsonPatch -> m ()
patchService k service patch = do
  token <- getServiceAccountToken
  let req = kPatchService token (kNamespace k) service patch
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- ==================================== Patch a service ===================== -}
{- | Get the service spec. -}
kGetServiceSpec
  :: BearerToken
  -> Namespace
  -> ServiceName
  -> ClientM ServiceSpec

{- | Get the service spec. -}
getServiceSpec :: (MonadIO m) => K8s -> ServiceName -> m ServiceSpec
getServiceSpec k service = do
  token <- getServiceAccountToken
  let req = kGetServiceSpec token (kNamespace k) service
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right spec -> pure spec


{- ==================================== Post a service ====================== -}
{- | Post a new service. -}
kPostService
  :: BearerToken
  -> Namespace
  -> ServiceSpec
  -> ClientM NoContent

{- | Post a new service. -}
postService :: (MonadIO m) => K8s -> ServiceSpec -> m ()
postService k service = do
  token <- getServiceAccountToken
  let req = kPostService token (kNamespace k) service
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- ==================================== Other stuff ========================= -}

kListPods
    :<|> kPostPod
    :<|> kDeletePod
    :<|> (\ f a b c -> f a b c (Just True) -> kGetPodSpec)
    :<|> kGetServiceSpec
    :<|> kPostService
    :<|> kPatchService
  =
    client (flatten (Proxy @KubernetesApi))


{- | The name of a service. -}
newtype ServiceName = ServiceName {
    unServiceName :: Text
  }
  deriving newtype (ToHttpApiData)


{- | The specification of a service. -}
newtype ServiceSpec = ServiceSpec {
    unServiceSpec :: Value
  }
  deriving newtype (FromJSON, ToJSON)


{- | A pod specification. -}
newtype PodSpec = PodSpec {
    unPodSpec :: Value
  }
  deriving newtype (FromJSON, ToJSON)


{- | A Kubernetes namespace. -}
newtype Namespace = Namespace {
    _unNamespace :: Text
  }
  deriving newtype (
    Eq, Ord, Show, IsString, ToHttpApiData, FromHttpApiData, ToJSON,
    FromJSON, ToJSONKey, FromJSONKey
  )


{- | The name of a pod. -}
newtype PodName = PodName {
    unPodName :: Text
  }
  deriving newtype (
    Eq, Ord, Show, IsString, ToHttpApiData, FromHttpApiData, ToJSON,
    FromJSON, ToJSONKey, FromJSONKey
  )


{- | Get the k8s service account token. -}
getServiceAccountToken :: (MonadIO m) => m BearerToken
getServiceAccountToken =
  fmap BearerToken
  . liftIO
  . TIO.readFile
  $ "/var/run/secrets/kubernetes.io/serviceaccount/token"


mkEnv :: K8s -> ClientEnv
mkEnv =
    mkEnv_ . kManager 
  where
    mkEnv_ :: Manager -> ClientEnv
    mkEnv_ manager =
      mkClientEnv
        manager
        (BaseUrl Https "kubernetes.default.svc" 443 "")


