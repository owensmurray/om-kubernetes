{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | Kubernetes interface utilities. -}
module OM.Kubernetes (
  newKManager,
  mkStartupMode,
  launch,
  getClusterGoal,
  findPeers,
  delete,
  selfTerminate,
  KManager,
  k8sConfig,
) where


import Control.Concurrent (threadDelay)
import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger (MonadLoggerIO, logDebug, logWarn)
import Data.Aeson ((.:), (.=), FromJSON, FromJSONKey, ToJSON, ToJSONKey,
  Value, object, parseJSON, toJSON, withObject)
import Data.Default.Class (def)
import Data.Map (Map)
import Data.Proxy (Proxy(Proxy))
import Data.Set (Set)
import Data.String (IsString, fromString)
import Data.Text (Text)
import Data.X509.CertificateStore (CertificateStore, readCertificateStore)
import Network.Connection (TLSSettings(TLSSettings))
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HostName (getHostName)
import Network.TLS (clientShared, clientSupported,
  clientUseServerNameIndication, defaultParamsClient, sharedCAStore,
  supportedCiphers)
import Network.TLS.Extra.Cipher (ciphersuite_default)
import OM.HTTP (BearerToken(BearerToken), AllTypes)
import OM.Legion (StartupMode(JoinCluster, NewCluster), ClusterGoal,
  ClusterName, Peer, legionPeer, parseLegionPeer)
import OM.Show (showj, showt)
import Servant.API ((:<|>)((:<|>)), NoContent(NoContent), (:>), Capture,
  DeleteNoContent, Description, Get, Header', JSON, PostNoContent,
  QueryParam, ReqBody, Required, Strict)
import Servant.Client (BaseUrl(BaseUrl), Scheme(Https), ClientEnv,
  client, mkClientEnv, runClientM)
import System.Environment (getArgs, getEnv)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text.IO as TIO
import qualified Text.Megaparsec as M
import qualified Text.Megaparsec.Char.Lexer as ML
import qualified Text.Mustache as Mustache (Template, substitute)
import qualified Text.Mustache.Compile as Mustache (embedSingleTemplate)


{- | A handle on the kubernetes service. -}
data KManager = KManager {
       kmNamespace :: Namespace,
         kmCluster :: ClusterName,
            kmSelf :: Peer,
         kmManager :: Manager,
                      {- ^
                        An http client manager configured to work against
                        the kubernetes api.
                      -}
    kmSpecTemplate :: SpecTemplate
  }


{- | Create a new KManager. -}
newKManager
  :: ( MonadIO m
     )
  => m KManager
newKManager = liftIO $ do
    hostname <- getHostName
    namespace <- fromString <$> getEnv "OM_KUBERNETES_NAMESPACE"
    case parseLegionPeer (fromString hostname) of
      Nothing -> fail $ "The host name doesn't work: " <> show hostname
      Just (clusterName, self) ->
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
            specTemplate <- getSpecTemplate manager namespace clusterName self
            pure KManager {
                   kmNamespace = namespace,
                     kmCluster = clusterName,
                        kmSelf = self,
                     kmManager = manager,
                kmSpecTemplate = specTemplate
              }
  where
    getSpecTemplate
      :: (MonadIO m)
      => Manager
      -> Namespace
      -> ClusterName
      -> Peer
      -> m SpecTemplate
    getSpecTemplate manager namespace clusterName peer = do
      token <- getServiceAccountToken
      let
        (pods :<|> _) = client (Proxy @KubernetesApi) token
        (_ :<|> _ :<|> _ :<|> get) = pods namespace
        req = get (legionPeer clusterName peer) (Just True)

      (liftIO . (`runClientM` mkEnv_ manager)) req >>= \case
        Left err -> fail (show err)
        Right template -> pure template

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
    :> PostNoContent '[AllTypes] NoContent
  :<|>
    Description "Delete a pod"
    :> Capture "pod-name" PodName
    :> DeleteNoContent '[AllTypes] NoContent
  :<|>
    Description "Get a pod spec"
    :> Capture "pod-name" PodName
    :> QueryParam "export" Bool
    :> Get '[JSON] SpecTemplate


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
            >=> (.: "cluster-goal")
            >=> parseGoal
          )
    where
      parseGoal :: (Monad m) => Text -> m ClusterGoal
      parseGoal str =
        case M.parseMaybe (ML.decimal @()) str of
          Nothing -> fail $ "Invalid cluster goal: " <> show str
          Just goal -> pure (fromInteger goal)


{- | A list of pods. -}
newtype PodList = PodList {
    unPodList :: [PodName]
  }
instance FromJSON PodList where
  parseJSON = withObject "Pod List" $ \o -> do
    list <- o .: "items"
    PodList <$> mapM ((.: "metadata") >=> (.: "name")) list


{- | Delete a pod. -}
delete
  :: ( MonadIO m
     )
  => KManager
  -> Peer
  -> m ()
delete manager peer = do
  token <- getServiceAccountToken
  let
    (pods :<|> _) = client (Proxy @KubernetesApi) token
    (_ :<|> _ :<|> del :<|> _) = pods (kmNamespace manager)
    req = del (podName manager peer)

  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> fail (show err)
    Right NoContent -> pure ()


{- | Get the pod name. -}
podName :: KManager -> Peer -> PodName
podName = legionPeer . kmCluster


{- | Launch a new legion cluster node. -}
launch
  :: ( MonadLoggerIO m
     )
  => KManager
  -> Peer
  -> m ()
launch manager peer = do
  token <- getServiceAccountToken
  let
    (pods :<|> _) = client (Proxy @KubernetesApi) token
    (_ :<|> post :<|> _) = pods (kmNamespace manager)
    req = post (podSpec manager peer)

  $(logDebug) $ "Launching: " <> showj (podSpec manager peer)
  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> do
      $(logDebug) $ "Failed with: " <> showt err
      fail (show err)
    Right NoContent -> pure ()


{- | Generate a pod spec. -}
podSpec :: KManager -> Peer -> Value
podSpec manager peer =
  let
    spec = kmSpecTemplate manager
    name = legionPeer (kmCluster manager) peer
  in
    toJSON spec {
      stMeta = Map.insert "name" name (stMeta spec),
      stSpec = Map.insert "hostname" name (stSpec spec)
    }
  


{- | A pod spec template. -}
data SpecTemplate = SpecTemplate {
    stMeta :: Map Text Value,
    stSpec :: Map Text Value
  }
instance FromJSON SpecTemplate where
  parseJSON = withObject "Spec object" $ \o ->
    SpecTemplate
      <$> o .: "metadata"
      <*> o .: "spec"
instance ToJSON SpecTemplate where
  toJSON t =
    object [
      "metadata" .= stMeta t,
      "spec" .= stSpec t
    ]



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
  => KManager
  -> m ClusterGoal
getClusterGoal manager = do
  token <- getServiceAccountToken
  let
    _ :<|> req = client (Proxy @KubernetesApi) token
  (liftIO . (`runClientM` mkEnv manager))
      (req (kmNamespace manager) (kmCluster manager))
    >>= \case
      Left err -> fail (show err)
      Right v -> pure (ciClusterGoal v)


mkEnv :: KManager -> ClientEnv
mkEnv = mkEnv_ . kmManager 


mkEnv_ :: Manager -> ClientEnv
mkEnv_ manager =
  mkClientEnv
    manager
    (BaseUrl Https "kubernetes.default.svc" 443 "")



{- | Query Kubernetes for all the peers in a cluster. -}
findPeers
  :: (MonadIO m)
  => KManager
  -> m (Set Peer)
findPeers manager = do
  token <- getServiceAccountToken
  let
    clusterName = kmCluster manager
    pods :<|> _ = client (Proxy @KubernetesApi) token
    req :<|> _ = pods (kmNamespace manager)
  (liftIO . (`runClientM` mkEnv manager)) req >>= \case
    Left err -> fail (show err)
    Right nodes ->
      (pure . Set.fromList) [
        peer
        | pod <- unPodList nodes
        , Just (c, peer) <- [parseLegionPeer (unPodName pod)]
        , c == clusterName
      ]


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


{- | Figure out how we are starting up. -}
mkStartupMode :: (MonadIO m)
  => KManager
  -> m (StartupMode e)
mkStartupMode kmanager = do
    let
      self = kmSelf kmanager
      clusterName = kmCluster kmanager
    goal <- getClusterGoal kmanager
    peers <- Set.delete self <$> findPeers kmanager
    pure $
      case Set.minView peers of
        Nothing -> NewCluster self goal clusterName
        Just (peer, _) -> JoinCluster self clusterName peer


{- | Terminate this pod. -}
selfTerminate :: (MonadLoggerIO m) => KManager -> m void
selfTerminate manager = do
  $(logWarn) "Self terminating."
  delete manager (kmSelf manager)
  liftIO (threadDelay 2_000_000)
  selfTerminate manager


{- |
  A command-line program that generates Kubernetes configs for
  self-managed clusters
-}
k8sConfig :: IO ()
k8sConfig =
    getArgs >>= \case
      [name, image] ->
        TIO.putStr
          (
            Mustache.substitute
              template
              (object ["name" .= name, "image" .= image])
          )
      _ -> fail "Usage: k8s-legion <name> <image>"
  where
    template :: Mustache.Template
    template = $(Mustache.embedSingleTemplate "k8s/k8s.mustache")


