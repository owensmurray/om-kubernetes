{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

{- |
  Description: Access the Kubernetes API from within the cluster.

  This module provides functions that access and operate on the
  Kubernetes API.  It is designed to be used from pods running within
  the K8s cluster itself and it won't work otherwise.
-}
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
  postRoleBinding,
  postRole,
  postServiceAccount,
  postNamespace,

  -- * Types
  JsonPatch(..),
  PodName(..),
  PodSpec(..),
  PodList(..),
  ServiceName(..),
  ServiceSpec(..),
  RoleBindingSpec(..),
  RoleSpec(..),
  ServiceAccountSpec(..),
  NamespaceSpec(..),
  Namespace(..),
) where


import Control.Exception.Safe (throw)
import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson ((.:), FromJSON, FromJSONKey, ToJSON, ToJSONKey, Value,
  encode, parseJSON, withObject)
import Data.Default.Class (def)
import Data.Proxy (Proxy(Proxy))
import Data.String (IsString)
import Data.Text (Text)
import Data.X509.CertificateStore (CertificateStore, readCertificateStore)
import Network.Connection (TLSSettings(TLSSettings))
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.TLS (clientShared, clientSupported,
  clientUseServerNameIndication, defaultParamsClient, sharedCAStore,
  supportedCiphers)
import Network.TLS.Extra.Cipher (ciphersuite_default)
import OM.HTTP (BearerToken(BearerToken))
import Servant.API ((:<|>)((:<|>)), NoContent(NoContent), (:>), Accept,
  Capture, DeleteNoContent, Description, Get, Header', JSON, MimeRender,
  PatchNoContent, PostNoContent, QueryParam, ReqBody, Required, Strict,
  contentType, mimeRender)
import Servant.API.Flatten (flatten)
import Servant.Client (BaseUrl(BaseUrl), Scheme(Https), ClientEnv,
  ClientM, client, mkClientEnv, runClientM)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Text.IO as TIO


{- | A subset of the kubernetes api spec. -}
type KubernetesApi = 
  Description "Kubernetes api"
    :> Header' [Required, Strict] "Authorization" BearerToken
    :> (
        "api"
        :> "v1"
        :> "namespaces"
        :> (
            ReqBody '[JSON] NamespaceSpec
            :> PostNoContent
          :<|>
            Capture "namespace" Namespace
            :> (
                Description "Pods API"
                :> "pods"
                :> PodsApi
              :<|>
                Description "Services API."
                :> "services"
                :> ServicesApi
              :<|>
                Description "Roll API"
                :> "roles"
                :> ReqBody '[JSON] RoleSpec
                :> PostNoContent
              :<|>
                Description "Service Account API"
                :> "serviceaccounts"
                :> ReqBody '[JSON] ServiceAccountSpec
                :> PostNoContent
            )
        )
      :<|>
        Description "Role Binding API"
        :> "apis"
        :> "rbac.authorization.k8s.io"
        :> "v1"
        :> "namespaces"
        :> Capture "namespace" Namespace
        :> "rolebindings"
        :> ReqBody '[JSON] RoleBindingSpec
        :> PostNoContent
    )


{- | A subset of the kubernetes api spec related to services. -}
type ServicesApi =
    Description "Get the cluster service."
    :> Capture "service-name" ServiceName
    :> Get '[JSON] ServiceSpec
  :<|>
    Description "Post a new serivce."
    :> ReqBody '[JSON] ServiceSpec
    :> PostNoContent
  :<|>
    Description "Update the cluster spec annotation."
    :> Capture "service-name" ServiceName
    :> ReqBody '[JsonPatch] JsonPatch
    :> PatchNoContent


{- | A handle on the kubernetes service. -}
newtype K8s = K8s {
    kManager :: Manager
                {- ^
                  An http client manager configured to work against the
                  kubernetes api.
                -}
  }


{- | Create a new 'K8s'. -}
newK8s
  :: ( MonadIO m
     )
  => m K8s
newK8s = liftIO $
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
    :> PostNoContent
  :<|>
    Description "Delete a pod"
    :> Capture "pod-name" PodName
    :> DeleteNoContent
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
listPods :: (MonadIO m) => K8s -> Namespace -> m PodList
listPods k namespace = do
  token <- getServiceAccountToken
  let req = kListPods token namespace
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right list -> pure list


{- ==================================== Post a new pod ====================== -}
{- | Create a new pod. -}
kPostPod :: BearerToken -> Namespace -> PodSpec -> ClientM NoContent

{- | Create a new pod. -}
postPod :: (MonadIO m) => K8s -> Namespace -> PodSpec -> m ()
postPod k namespace spec = do
  token <- getServiceAccountToken
  let req = kPostPod token namespace spec
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Delete a pod ======================== -}
{- | Delete a pod. -}
kDeletePod :: BearerToken -> Namespace -> PodName -> ClientM NoContent

{- | Delete a pod. -}
deletePod :: (MonadIO m) => K8s -> Namespace -> PodName -> m ()
deletePod k namespace podName = do
  token <- getServiceAccountToken
  let req = kDeletePod token namespace podName
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()
  

{- ==================================== Delete a pod ======================== -}
{- | Get the spec of a specific pod. -}
kGetPodSpec :: BearerToken -> Namespace -> PodName -> ClientM PodSpec

{- | Get the spec of a specific pod. -}
getPodSpec :: (MonadIO m) => K8s -> Namespace -> PodName -> m PodSpec
getPodSpec k namespace podName = do
  token <- getServiceAccountToken
  let req = kGetPodSpec token namespace podName
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
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
patchService :: (MonadIO m) => K8s -> Namespace -> ServiceName -> JsonPatch -> m ()
patchService k namespace service patch = do
  token <- getServiceAccountToken
  let req = kPatchService token namespace service patch
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Get a service Spec ================== -}
{- | Get the service spec. -}
kGetServiceSpec
  :: BearerToken
  -> Namespace
  -> ServiceName
  -> ClientM ServiceSpec

{- | Get the service spec. -}
getServiceSpec
  :: (MonadIO m)
  => K8s
  -> Namespace
  -> ServiceName
  -> m ServiceSpec
getServiceSpec k namespace service = do
  token <- getServiceAccountToken
  let req = kGetServiceSpec token namespace service
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right spec -> pure spec


{- ==================================== Post a service ====================== -}
{- | Post a new service. -}
kPostService
  :: BearerToken
  -> Namespace
  -> ServiceSpec
  -> ClientM NoContent

{- | Post a new service. -}
postService :: (MonadIO m) => K8s -> Namespace -> ServiceSpec -> m ()
postService k namespace service = do
  token <- getServiceAccountToken
  let req = kPostService token namespace service
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Post Role Binding =================== -}
{- | Post a role binding. -}
kPostRoleBinding
  :: BearerToken
  -> Namespace
  -> RoleBindingSpec
  -> ClientM NoContent

{- | Post a role binding. -}
postRoleBinding :: (MonadIO m) => K8s -> Namespace -> RoleBindingSpec -> m ()
postRoleBinding k namespace roleBinding = do
  token <- getServiceAccountToken
  let req = kPostRoleBinding token namespace roleBinding
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Post Role =========================== -}
{- | Post a Role. -}
kPostRole :: BearerToken -> Namespace -> RoleSpec -> ClientM NoContent

{- | Post a Role. -}
postRole :: (MonadIO m) => K8s -> Namespace -> RoleSpec -> m ()
postRole k namespace role = do
  token <- getServiceAccountToken
  let req = kPostRole token namespace role
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Post Service Account ================ -}
{- | Post a service account. -}
kPostServiceAccount
  :: BearerToken
  -> Namespace
  -> ServiceAccountSpec
  -> ClientM NoContent

{- | Post a service account. -}
postServiceAccount :: (MonadIO m) => K8s -> Namespace -> ServiceAccountSpec -> m ()
postServiceAccount k namespace serviceAccount = do
  token <- getServiceAccountToken
  let req = kPostServiceAccount token namespace serviceAccount
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Post a Namspace ===================== -}
{- | Post a Namespace. -}
kPostNamespace :: BearerToken -> NamespaceSpec -> ClientM NoContent

{- | Post a Namespace. -}
postNamespace :: (MonadIO m) => K8s -> NamespaceSpec -> m ()
postNamespace k namespace = do
  token <- getServiceAccountToken
  let req = kPostNamespace token namespace
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right NoContent -> pure ()


{- ==================================== Other stuff ========================= -}

kPostNamespace
    :<|> kListPods
    :<|> kPostPod
    :<|> kDeletePod
    :<|> (\ f a b c -> f a b c (Just True) -> kGetPodSpec)
    :<|> kGetServiceSpec
    :<|> kPostService
    :<|> kPatchService
    :<|> kPostRole
    :<|> kPostServiceAccount
    :<|> kPostRoleBinding
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


{- | The representation of Role Binding. -}
newtype RoleBindingSpec = RoleBindingSpec {
    unRoleBindingSpec :: Value
  }
  deriving newtype (ToJSON, FromJSON)


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


{- | The representation of a Role. -}
newtype RoleSpec = RoleSpec {
    unRoleSpec :: Value
  }
  deriving newtype (ToJSON, FromJSON)


{- | The representation of a service account. -}
newtype ServiceAccountSpec = ServiceAccountSpec {
    unServiceAccountSpec :: Value
  }
  deriving newtype (ToJSON, FromJSON)


{- | The representation of a Namespace specification. -}
newtype NamespaceSpec = NamespaceSpec {
    unNamespaceSpec :: Value
  }
  deriving newtype (ToJSON, FromJSON)


