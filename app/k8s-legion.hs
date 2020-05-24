
{- | k8s-legion program entry point. -}
module Main (main) where

import qualified OM.Kubernetes

main :: IO ()
main = OM.Kubernetes.k8sConfig

