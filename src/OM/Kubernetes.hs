{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

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
  getPodTemplate,

  -- * Types
  JsonPatch(..),
  PodName(..),
  PodSpec(..),
  ServiceName(..),
  ServiceSpec(..),
  RoleBindingSpec(..),
  RoleSpec(..),
  ServiceAccountSpec(..),
  NamespaceSpec(..),
  Namespace(..),
  PodTemplateName(..),
  PodTemplateSpec(..),
) where


import Control.Exception.Safe (throw)
import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson ((.:), FromJSON, FromJSONKey, ToJSON, ToJSONKey, Value,
  encode, parseJSON, withObject)
import Data.Default.Class (def)
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
import Servant.API (Accept(contentType), MimeRender(mimeRender),
  NoContent(NoContent), (:>), Capture, DeleteNoContent, Description, Get,
  Header', JSON, PatchNoContent, PostNoContent, ReqBody, Required, Strict)
import Servant.API.Generic (GenericMode((:-)), Generic)
import Servant.Client (BaseUrl(BaseUrl), Scheme(Https), ClientEnv,
  ClientM, mkClientEnv, runClientM)
import Servant.Client.Generic (genericClient)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Text.IO as TIO


{- | A subset of the kubernetes api spec. -}
data KubernetesApi mode = KubernetesApi
  { kPostNamespaceR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> ReqBody '[JSON] NamespaceSpec
      :> PostNoContent
  , kListPodsR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "pods"
      :> Description "List pods"
      :> Get '[JSON] PodNameList
  , kPostPodR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "pods"
      :> Description "Post a pod definition"
      :> ReqBody '[JSON] PodSpec
      :> PostNoContent
  , kDeletePodR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "pods"
      :> Description "Delete a pod"
      :> Capture "pod-name" PodName
      :> DeleteNoContent
  , kGetPodSpecR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "pods"
      :> Description "Get a pod spec"
      :> Capture "pod-name" PodName
      :> Get '[JSON] PodSpec
  , kGetServiceSpecR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "services"
      :> Description "Get the cluster service."
      :> Capture "service-name" ServiceName
      :> Get '[JSON] ServiceSpec
  , kPostServiceR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "services"
      :> Description "Post a new serivce."
      :> ReqBody '[JSON] ServiceSpec
      :> PostNoContent
  , kPatchServiceR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "services"
      :> Description "Update the cluster spec annotation."
      :> Capture "service-name" ServiceName
      :> ReqBody '[JsonPatch] JsonPatch
      :> PatchNoContent
  , kPostRoleR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> Description "Roll API"
      :> "roles"
      :> ReqBody '[JSON] RoleSpec
      :> PostNoContent
  , kPostServiceAccountR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> Description "Service Account API"
      :> "serviceaccounts"
      :> ReqBody '[JSON] ServiceAccountSpec
      :> PostNoContent
  , kGetPodTemplateR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> "api"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> Description "Pod Templates API"
      :> "podtemplates"
      :> Capture "template-name" PodTemplateName
      :> Get '[JSON] PodTemplateSpec
  , kPostRoleBindingR :: mode
      :- Header' [Required, Strict] "Authorization" BearerToken
      :> Description "Role Binding API"
      :> "apis"
      :> "rbac.authorization.k8s.io"
      :> "v1"
      :> "namespaces"
      :> Capture "namespace" Namespace
      :> "rolebindings"
      :> ReqBody '[JSON] RoleBindingSpec
      :> PostNoContent
  }
  deriving stock (Generic)


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


{- | A list of pods. -}
newtype PodNameList = PodNameList {
    unPodNameList :: [PodName]
  }
instance FromJSON PodNameList where
  parseJSON = withObject "Pod List (Names)" $ \o -> do
    list <- o .: "items"
    PodNameList <$> mapM ((.: "metadata") >=> (.: "name")) list


{- ==================================== List all pods ======================= -}
{- | Get the list of pods. -}
kListPods :: BearerToken -> Namespace -> ClientM PodNameList

{- | List the pods, returning a list of names. -}
listPods :: (MonadIO m) => K8s -> Namespace -> m [PodName]
listPods k namespace = do
  token <- getServiceAccountToken
  let req = kListPods token namespace
  liftIO $ runClientM req (mkEnv k) >>= \case
    Left err -> liftIO (throw err)
    Right list -> pure (unPodNameList list)


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


{- ==================================== Get a Pod Template Spec ============= -}
{- | Get the pod template. -}
kGetPodTemplate
  :: BearerToken
  -> Namespace
  -> PodTemplateName
  -> ClientM PodTemplateSpec

{- | Get the pod template. -}
getPodTemplate
  :: (MonadIO m)
  => K8s
  -> Namespace
  -> PodTemplateName
  -> m PodTemplateSpec
getPodTemplate k namespace templateName = do
  token <- getServiceAccountToken
  let req = kGetPodTemplate token namespace templateName
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

KubernetesApi
    { kPostNamespaceR = kPostNamespace
    , kListPodsR = kListPods
    , kPostPodR = kPostPod
    , kDeletePodR = kDeletePod
    , kGetPodSpecR = kGetPodSpec
    , kGetServiceSpecR = kGetServiceSpec
    , kPostServiceR = kPostService
    , kPatchServiceR = kPatchService
    , kPostRoleR = kPostRole
    , kPostServiceAccountR = kPostServiceAccount
    , kGetPodTemplateR = kGetPodTemplate
    , kPostRoleBindingR = kPostRoleBinding
    }
  =
    genericClient


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


{- | The name of a pod template. -}
newtype PodTemplateName =  PodTemplateName
  { unPodTemplateName :: Text
  }
  deriving newtype (
    Eq, Ord, Show, IsString, ToHttpApiData, FromHttpApiData, ToJSON,
    FromJSON, ToJSONKey, FromJSONKey
  )


{- | The specification of a pod template.  -}
newtype PodTemplateSpec = PodTempalteSpec
  { unPodTemplateSpec :: Value
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


