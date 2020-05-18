{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | Kubernetes interface utilities. -}
module OM.Kubernetes (
  launch,
  getClusterGoal,
  findPeers,
  delete,
  KManager,
  newKManager,
  Namespace(..),
  PodSpec(..),
  PodName(..),
) where


import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson ((.:), FromJSON, FromJSONKey, ToJSON, ToJSONKey, Value,
  parseJSON, withObject)
import Data.Default.Class (def)
import Data.Proxy (Proxy(Proxy))
import Data.Set (Set)
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
import OM.Deploy.Types (ClusterGoal(ClusterGoal), ClusterName, NodeName,
  PeerOrdinal, legionPeer, parseLegionPeer)
import OM.HTTP (BearerToken(BearerToken), AllTypes)
import OM.Legion (Peer)
import Servant.API ((:<|>)((:<|>)), NoContent(NoContent), (:>), Capture,
  DeleteNoContent, Description, Get, Header', JSON, PostNoContent,
  ReqBody, Required, Strict)
import Servant.Client (BaseUrl(BaseUrl), Scheme(Https), ClientEnv,
  client, mkClientEnv, runClientM)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Set as Set
import qualified Data.Text.IO as TIO
import qualified Text.Megaparsec as M
import qualified Text.Megaparsec.Char.Lexer as ML


{- | An http client manager configured to work against the kubernetes api. -}
newtype KManager pod = KManager {
    unKManager :: Manager
  }


{- | Create a new KManager. -}
newKManager
  :: ( MonadIO m
     )
  => m (KManager pod)
newKManager =
    liftIO $
      readCertificateStore crtLocation >>= \case
        Nothing -> fail "Can't load K8S CA certificate."
        Just store ->
          KManager
            <$> newManager
                  (
                    mkManagerSettings
                      (k8sTLSSettings store)
                      Nothing
                  )
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

      :<|> Description "Get the cluster service."
        :> "api"
        :> "v1"
        :> "namespaces"
        :> Capture "namespace" Namespace
        :> "services"
        :> Capture "cluster-name" ClusterName
        :> Get '[JSON] ClusterInfo
    )


{- | A subset of the kubernetes api spec related to pods. -}
type PodsApi =
    Description "List pods"
    :> Get '[JSON] PodList
  :<|>
    Description "Post a pod definition"
    :> ReqBody '[JSON] Value
    :> PostNoContent '[JSON] NoContent
  :<|>
    Description "Delete a pod"
    :> Capture "pod-name" PodName
    :> DeleteNoContent '[AllTypes] NoContent


{- | A representation of a Friendlee K8S service. -}
newtype ClusterInfo = ClusterInfo {
    ciClusterGoal :: ClusterGoal
  }
instance FromJSON ClusterInfo where
  parseJSON =
      withObject "Service object" $
        fmap ClusterInfo
        . (
            (.: "metadata")
            >=> (.: "annotations")
            >=> (.: "friendlee-cluster-goal")
            >=> parseGoal
          )
    where
      parseGoal :: (Monad m) => Text -> m ClusterGoal
      parseGoal str =
        case M.parseMaybe (ML.decimal @()) str of
          Nothing -> fail $ "Invalid cluster goal: " <> show str
          Just goal -> pure (ClusterGoal goal)


{- | A list of pods. -}
newtype PodList = PodList {
    unPodList :: [NodeName]
  }
instance FromJSON PodList where
  parseJSON = withObject "Pod List" $ \o -> do
    list <- o .: "items"
    PodList <$> mapM ((.: "metadata") >=> (.: "name")) list


{- | Delete a pod. -}
delete
  :: forall m pod.
     ( MonadIO m
     , PodSpec pod
     )
  => KManager pod
  -> Namespace
  -> ClusterName
  -> PeerOrdinal
  -> m ()
delete manager namespace clusterName peer = do
  token <- getServiceAccountToken
  let
    (pods :<|> _) = client (Proxy @KubernetesApi) token
    (_ :<|> _ :<|> del) = pods namespace
    req = del (podName (Proxy @pod) clusterName peer)

  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- | Launch a new legion cluster node. -}
launch
  :: forall m pod.
     ( MonadIO m
     , PodSpec pod
     )
  => KManager pod
  -> Namespace
  -> ClusterName
  -> PeerOrdinal
  -> m ()
launch manager namespace clusterName peer = do
  token <- getServiceAccountToken
  let
    (pods :<|> _) = client (Proxy @KubernetesApi) token
    (_ :<|> post :<|> _) = pods namespace
    req =
      post (
        podSpec
          (Proxy @pod)
          clusterName
          peer
      )

  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- | Get the k8s service account token. -}
getServiceAccountToken :: (MonadIO m) => m BearerToken
getServiceAccountToken =
  fmap BearerToken
  . liftIO
  . TIO.readFile
  $ "/var/run/secrets/kubernetes.io/serviceaccount/token"


{- | Get the cluster goal from the service annotations. -}
getClusterGoal
  :: ( MonadIO m
     )
  => KManager pod
  -> Namespace
  -> ClusterName
  -> m ClusterGoal
getClusterGoal manager namespace clusterName = do
  token <- getServiceAccountToken
  let
    _ :<|> req = client (Proxy @KubernetesApi) token
  (liftIO . (`runClientM` mkEnv manager))
      (req namespace clusterName)
    >>= \case
      Left err -> fail (show err)
      Right v -> pure (ciClusterGoal v)


mkEnv :: KManager pod -> ClientEnv
mkEnv manager =
  mkClientEnv
    (unKManager manager)
    (BaseUrl Https "kubernetes.default.svc" 443 "")



{- | Query Kubernetes for all the peers in a cluster. -}
findPeers
  :: (MonadIO m)
  => KManager pod
  -> Namespace
  -> ClusterName
  -> m (Set Peer)
findPeers manager namespace clusterName = do
  token <- getServiceAccountToken
  let
    pods :<|> _ = client (Proxy @KubernetesApi) token
    req :<|> _ = pods namespace
  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> fail (show err)
    Right nodes ->
      (pure . Set.fromList) [
        legionPeer clusterName ord
        | node <- unPodList nodes
        , Just (c, ord) <- [parseLegionPeer node]
        , c == clusterName
      ]


{- | A Kubernetes namespace. -}
newtype Namespace = Namespace {
    unNamespace :: Text
  }
  deriving newtype (
    Eq, Ord, Show, IsString, ToHttpApiData, FromHttpApiData, ToJSON,
    FromJSON, ToJSONKey, FromJSONKey
  )


{- | The class of types that can represent a kubernetes pod. -}
class PodSpec a where
  {- | Produe the full pod spec. -}
  podSpec :: proxy a -> ClusterName -> PeerOrdinal -> Value

  {- | Produe just the name of the pod. -}
  podName :: proxy a -> ClusterName -> PeerOrdinal -> PodName


{- | The name of a pod. -}
newtype PodName = PodName {
    unPodName :: Text
  }
  deriving newtype (
    Eq, Ord, Show, IsString, ToHttpApiData, FromHttpApiData, ToJSON,
    FromJSON, ToJSONKey, FromJSONKey
  )


