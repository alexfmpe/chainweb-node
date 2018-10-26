{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module: P2P.Node.Configuration
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module P2P.Node.Configuration
(
-- * Peer Id
  PeerId(..)
, createPeerId
, peerIdToText
, peerIdFromText
, unsafePeerIdFromText
, pPeerId

-- * Peer Info
, PeerInfo(..)
, peerId
, peerAddr
, pPeerInfo
, arbitraryPeerInfo

, P2pNetworkId(..)
, p2pNetworkIdToText
, p2pNetworkIdFromText
, unsafeP2pNetworkIdFromText
, pP2pNetworkId

-- * P2P Configuration
, P2pConfiguration(..)
, p2pConfigPeerId
, p2pConfigNetworkId
, p2pConfigHostAddress
, p2pConfigMaxSessionCount
, p2pConfigMaxPeerCount
, p2pConfigSessionTimeout
, p2pConfigKnownPeers
, p2pConfigPeerDbFilePath
, defaultP2pConfiguration
, pP2pConfiguration
) where

import Configuration.Utils

import Control.Lens hiding ((.=))
import Control.Monad.Catch

import Data.Hashable
import Data.Maybe
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup hiding (option)
#endif
import qualified Data.Text as T
import qualified Data.UUID as V4
import qualified Data.UUID.V4 as V4

import GHC.Generics (Generic)

import Numeric.Natural

import Test.QuickCheck
import Test.QuickCheck.Instances ({- Arbitrary V4.UUID -})

-- Internal imports

import Chainweb.ChainId
import Chainweb.HostAddress
import Chainweb.Time
import Chainweb.Utils hiding (check)
import Chainweb.Version

-- -------------------------------------------------------------------------- --
-- Peer Id

newtype PeerId = PeerId V4.UUID
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (Hashable)
    deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey, Arbitrary)

createPeerId :: IO PeerId
createPeerId = PeerId <$> V4.nextRandom
{-# INLINE createPeerId #-}

peerIdToText :: PeerId -> T.Text
peerIdToText (PeerId u) = sshow u
{-# INLINE peerIdToText #-}

peerIdFromText :: MonadThrow m => T.Text -> m PeerId
peerIdFromText t = (PeerId <$> V4.fromString (T.unpack t))
    ??? TextFormatException ("Failed to parse peer id \"" <> t <> "\".")
{-# INLINE peerIdFromText #-}

unsafePeerIdFromText :: String -> PeerId
unsafePeerIdFromText = PeerId . fromJust . V4.fromString
{-# INLINE unsafePeerIdFromText #-}

instance HasTextRepresentation PeerId where
    toText = peerIdToText
    {-# INLINE toText #-}
    fromText = peerIdFromText
    {-# INLINE fromText #-}

pPeerId :: Maybe String -> OptionParser PeerId
pPeerId service = textOption
    % prefixLong service "peer-id"
{-# INLINE pPeerId #-}

-- -------------------------------------------------------------------------- --
-- Peer Info

-- | TODO: eventually this should have more information, like, for instance,
-- the API version that the peer supports, public key, etc.
--
data PeerInfo = PeerInfo
    { _peerId :: !PeerId
    , _peerAddr :: !HostAddress
    }
    deriving (Show, Eq, Ord, Generic, Hashable)

makeLenses ''PeerInfo

instance ToJSON PeerInfo where
    toJSON a = object
        [ "id" .= _peerId a
        , "address" .= _peerAddr a
        ]
    {-# INLINE toJSON #-}

instance FromJSON PeerInfo where
    parseJSON = withObject "PeerInfo" $ \o -> PeerInfo
        <$> o .: "id"
        <*> o .: "address"
    {-# INLINE parseJSON #-}

arbitraryPeerInfo :: Gen PeerInfo
arbitraryPeerInfo = PeerInfo <$> arbitrary <*> arbitrary

instance Arbitrary PeerInfo where
    arbitrary = arbitraryPeerInfo

pPeerInfo :: Maybe String -> MParser PeerInfo
pPeerInfo service = id
    <$< peerId .:: pPeerId service
    <*< peerAddr %:: pHostAddress service
{-# INLINE pPeerInfo #-}

-- -------------------------------------------------------------------------- --
-- Network ID

data P2pNetworkId
    = ChainNetwork ChainId
    | CutNetwork
    deriving (Show, Eq, Ord, Generic)

p2pNetworkIdToText :: P2pNetworkId -> T.Text
p2pNetworkIdToText CutNetwork = "cut"
p2pNetworkIdToText (ChainNetwork cid) = "chain/" <> chainIdToText cid
{-# INLINE p2pNetworkIdToText #-}

p2pNetworkIdFromText :: MonadThrow m => T.Text -> m P2pNetworkId
p2pNetworkIdFromText "cut" = return CutNetwork
p2pNetworkIdFromText t = case T.break (== '/') t of
    (a, b)
        | a == "chain" -> ChainNetwork <$> chainIdFromText (T.drop 1 b)
        | T.null b -> throwM . TextFormatException $ "missing '/' in P2P network id: \"" <> t <> "\"."
        | otherwise -> throwM $ TextFormatException $ "unrecognized P2P network id: \"" <> t <> "\"."

unsafeP2pNetworkIdFromText :: T.Text -> P2pNetworkId
unsafeP2pNetworkIdFromText = fromJust . p2pNetworkIdFromText
{-# INLINE unsafeP2pNetworkIdFromText #-}

instance ToJSON P2pNetworkId where
    toJSON = toJSON . p2pNetworkIdToText
    {-# INLINE toJSON #-}

instance FromJSON P2pNetworkId where
    parseJSON = parseJsonFromText "P2pNetworkId"
    {-# INLINE parseJSON #-}

instance HasTextRepresentation P2pNetworkId where
    toText = p2pNetworkIdToText
    {-# INLINE toText #-}
    fromText = p2pNetworkIdFromText
    {-# INLINE fromText #-}

pP2pNetworkId :: OptionParser P2pNetworkId
pP2pNetworkId = textOption
    % long "network-id"

instance Arbitrary P2pNetworkId where
    arbitrary = frequency
        [ (1, pure CutNetwork)
        , (5, ChainNetwork <$> arbitrary)
        ]

-- -------------------------------------------------------------------------- --
-- P2P Configuration

-- | Configuration of the Network
--
-- TODO: add ChainwebVersion?
--
data P2pConfiguration = P2pConfiguration
    { _p2pConfigPeerId :: !(Maybe PeerId)
    , _p2pConfigHostAddress :: !HostAddress
    , _p2pConfigNetworkId :: !P2pNetworkId
    , _p2pConfigMaxSessionCount :: !Natural
        -- ^ number of active peers
    , _p2pConfigMaxPeerCount :: !Natural
        -- ^ total number of peers
    , _p2pConfigSessionTimeout :: !Seconds
        -- ^ interval at which peers are rotated out of the active set
    , _p2pConfigKnownPeers :: ![PeerInfo]
    , _p2pConfigPeerDbFilePath :: !(Maybe FilePath)
    }
    deriving (Generic)

makeLenses ''P2pConfiguration

defaultP2pConfiguration :: ChainwebVersion -> P2pConfiguration
defaultP2pConfiguration Test = P2pConfiguration
    { _p2pConfigPeerId = Nothing
    , _p2pConfigHostAddress = unsafeHostAddressFromText "localhost:1789"
    , _p2pConfigNetworkId = ChainNetwork (testChainId 0)
    , _p2pConfigMaxSessionCount = 10
    , _p2pConfigMaxPeerCount = 50
    , _p2pConfigSessionTimeout = 60
    , _p2pConfigKnownPeers =
        [ PeerInfo
            (unsafePeerIdFromText "525ff65f-9240-4ada-9c36-fe7da982b4b4")
            (unsafeHostAddressFromText "localhost:1789")
        ]
    , _p2pConfigPeerDbFilePath = Nothing
    }

defaultP2pConfiguration _ = error "TODO not implemented"

instance ToJSON P2pConfiguration where
    toJSON o = object
        [ "peerId" .= _p2pConfigPeerId o
        , "hostAddress" .= _p2pConfigHostAddress o
        , "networkId" .= _p2pConfigNetworkId o
        , "maxSessionCount" .= _p2pConfigMaxSessionCount o
        , "maxPeerCount" .= _p2pConfigMaxPeerCount o
        , "sessionTimeout" .= _p2pConfigSessionTimeout o
        , "peers" .= _p2pConfigKnownPeers o
        , "peerDbFilePath" .= _p2pConfigPeerDbFilePath o
        ]

instance FromJSON (P2pConfiguration -> P2pConfiguration) where
    parseJSON = withObject "P2pExampleConfig" $ \o -> id
        <$< p2pConfigPeerId ..: "peerId" % o
        <*< p2pConfigHostAddress %.: "hostAddress" % o
        <*< p2pConfigNetworkId ..: "networkId" % o
        <*< p2pConfigMaxSessionCount ..: "maxSessionCount" % o
        <*< p2pConfigMaxPeerCount ..: "maxPeerCount" % o
        <*< p2pConfigSessionTimeout ..: "sessionTimeout" % o
        <*< p2pConfigKnownPeers . from leftMonoidalUpdate %.: "peers" % o
        <*< p2pConfigPeerDbFilePath ..: "peerDbFilePath" % o

pP2pConfiguration :: Maybe P2pNetworkId -> MParser P2pConfiguration
pP2pConfiguration networkId = id
    <$< p2pConfigPeerId .:: fmap Just % pPeerId net
    <*< p2pConfigHostAddress %:: pHostAddress net
    <*< p2pConfigMaxSessionCount .:: option auto
        % prefixLong net "p2p-max-session-count"
        <> suffixHelp net "maximum number of sessions that are active at any time"
    <*< p2pConfigMaxPeerCount .:: option auto
        % prefixLong net "p2p-max-peer-count"
        <> suffixHelp net "maximum number of entries in the peer database"
    <*< p2pConfigSessionTimeout .:: textOption
        % prefixLong net "p2p-session-timeout"
        <> suffixHelp net "timeout for sessions in seconds"
    -- <*< p2pConfigKnownPeers .:: option auto
    <*< p2pConfigPeerDbFilePath .:: fmap Just % fileOption
        % prefixLong net "p2p-peer-database-filepath"
        <> suffixHelp net "file where the peer database is stored"
  where
    net = T.unpack . p2pNetworkIdToText <$> networkId