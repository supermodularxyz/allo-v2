// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {AccessControl} from "@openzeppelin/access/AccessControl.sol";

import {Metadata} from "./libraries/Metadata.sol";

contract Registry is AccessControl {
    /// @notice Custom errors
    error NO_ACCESS_TO_ROLE();
    error NONCE_NOT_AVAILABLE();
    error NOT_PENDING_OWNER();

    /// @notice Struct to hold details of an identity
    struct Identity {
        uint256 nonce;
        string name;
        Metadata metadata;
        address owner;
        address pendingOwner;
        address anchor;
    }

    /// ==========================
    /// === Storage Variables ====
    /// ==========================

    /// @notice Identity.id -> Identity
    mapping(bytes32 => Identity) public identitiesById;

    /// @notice anchor -> Identity.id
    mapping(address => bytes32) public anchorToIdentityId;

    /// ======================
    /// ======= Events =======
    /// ======================

    event IdentityCreated(
        bytes32 indexed identityId, uint256 nonce, string name, Metadata metadata, address owner, address anchor
    );
    event IdentityNameUpdated(bytes32 indexed identityId, string name, address anchor);
    event IdentityMetadataUpdated(bytes32 indexed identityId, Metadata metadata);
    event IdentityOwnerUpdated(bytes32 indexed identityId, address owner);
    event IdentityPendingOwnerUpdated(bytes32 indexed identityId, address pendingOwner);

    /// ====================================
    /// =========== Modifier ===============
    /// ====================================

    modifier isIdentityOwner(bytes32 _identityId) {
        if (!isOwnerOfIdentity(_identityId, msg.sender)) {
            revert NO_ACCESS_TO_ROLE();
        }
        _;
    }

    /// ====================================
    /// ==== External/Public Functions =====
    /// ====================================

    /// @notice Retrieve identity by identityId
    /// @param identityId The identityId of the identity
    function getIdentityById(bytes32 identityId) public view returns (Identity memory) {
        return identitiesById[identityId];
    }

    /// @notice Retrieve identity by anchor
    /// @param anchor The anchor of the identity
    function getIdentityByAnchor(address anchor) public view returns (Identity memory) {
        bytes32 identityId = anchorToIdentityId[anchor];
        return identitiesById[identityId];
    }

    /// @notice Creates a new identity
    /// @dev This will also set the attestation address generated from msg.sender and name
    /// @param _nonce Nonce used to generate identityId
    /// @param _name The name of the identity
    /// @param _metadata The metadata of the identity
    /// @param _members The members of the identity
    /// @param _owner The owner of the identity
    function createIdentity(
        uint256 _nonce,
        string memory _name,
        Metadata memory _metadata,
        address _owner,
        address[] memory _members
    ) external returns (bytes32) {
        bytes32 identityId = _generateIdentityId(_nonce);

        if (identitiesById[identityId].anchor != address(0)) {
            revert NONCE_NOT_AVAILABLE();
        }

        Identity memory identity = Identity({
            nonce: _nonce,
            name: _name,
            metadata: _metadata,
            owner: _owner,
            pendingOwner: address(0),
            anchor: _generateAnchor(identityId, _name)
        });

        identitiesById[identityId] = identity;
        anchorToIdentityId[identity.anchor] = identityId;

        // assign roles
        uint256 memberLength = _members.length;
        for (uint256 i = 0; i < memberLength;) {
            _grantRole(identityId, _members[i]);
            unchecked {
                i++;
            }
        }

        emit IdentityCreated(
            identityId, identity.nonce, identity.name, identity.metadata, identity.owner, identity.anchor
        );

        return identityId;
    }

    /// @notice Updates the name of the identity and generates new anchor
    /// @param _identityId The identityId of the identity
    /// @param _name The new name of the identity
    /// @dev Only owner can update the name.
    function updateIdentityName(bytes32 _identityId, string memory _name)
        external
        isIdentityOwner(_identityId)
        returns (address)
    {
        address anchor = _generateAnchor(_identityId, _name);

        Identity storage identity = identitiesById[_identityId];
        identity.name = _name;

        // clear old anchor
        anchorToIdentityId[identity.anchor] = bytes32(0);

        // set new anchor
        identity.anchor = anchor;
        anchorToIdentityId[anchor] = _identityId;

        emit IdentityNameUpdated(_identityId, _name, anchor);

        // TODO: should we return identity
        return anchor;
    }

    /// @notice update the metadata of the identity
    /// @param _identityId The identityId of the identity
    /// @param _metadata The new metadata of the identity
    /// @dev Only owner can update metadata
    function updateIdentityMetadata(bytes32 _identityId, Metadata memory _metadata)
        external
        isIdentityOwner(_identityId)
    {
        identitiesById[_identityId].metadata = _metadata;

        emit IdentityMetadataUpdated(_identityId, _metadata);
    }

    /// @notice Returns if the given address is an owner or member of the identity
    /// @param _identityId The identityId of the identity
    /// @param _account The address to check
    function isOwnerOrMemberOfIdentity(bytes32 _identityId, address _account) public view returns (bool) {
        return isOwnerOfIdentity(_identityId, _account) || isMemberOfIdentity(_identityId, _account);
    }

    /// @notice Returns if the given address is an owner of the identity
    /// @param _identityId The identityId of the identity
    /// @param _owner The address to check
    function isOwnerOfIdentity(bytes32 _identityId, address _owner) public view returns (bool) {
        return identitiesById[_identityId].owner == _owner;
    }

    /// @notice Returns if the given address is an member of the identity
    /// @param _identityId The identityId of the identity
    /// @param _member The address to check
    function isMemberOfIdentity(bytes32 _identityId, address _member) public view returns (bool) {
        return hasRole(_identityId, _member);
    }

    /// @notice Updates the pending owner of the identity
    /// @param _identityId The identityId of the identity
    /// @param _pendingOwner New pending owner
    function updateIdentityPendingOwner(bytes32 _identityId, address _pendingOwner)
        external
        isIdentityOwner(_identityId)
    {
        identitiesById[_identityId].pendingOwner = _pendingOwner;

        emit IdentityPendingOwnerUpdated(_identityId, _pendingOwner);
    }

    /// @notice Transfers the ownership of the identity to the pending owner
    /// @param _identityId The identityId of the identity
    /// @dev Only pending owner can claim ownership.
    function acceptIdentityOwnership(bytes32 _identityId) external {
        Identity storage identity = identitiesById[_identityId];

        if (msg.sender != identity.pendingOwner) {
            revert NOT_PENDING_OWNER();
        }

        identity.owner = identity.pendingOwner;
        identity.pendingOwner = address(0);

        emit IdentityOwnerUpdated(_identityId, identity.owner);
    }

    /// @notice Adds members to the identity
    /// @param _identityId The identityId of the identity
    /// @param _members The members to add
    /// @dev Only owner can add members
    function addMembers(bytes32 _identityId, address[] memory _members) external isIdentityOwner(_identityId) {
        uint256 memberLength = _members.length;

        for (uint256 i = 0; i < memberLength;) {
            _grantRole(_identityId, _members[i]);
            unchecked {
                i++;
            }
        }
    }

    /// @notice Removes members from the identity
    /// @param _identityId The identityId of the identity
    /// @param _members The members to remove
    /// @dev Only owner can remove members
    function removeMembers(bytes32 _identityId, address[] memory _members) external isIdentityOwner(_identityId) {
        uint256 memberLength = _members.length;

        for (uint256 i = 0; i < memberLength;) {
            _revokeRole(_identityId, _members[i]);
            unchecked {
                i++;
            }
        }
    }

    /// ====================================
    /// ======== Internal Functions ========
    /// ====================================

    /// @notice Generates the anchor for the given identityId and name
    /// @param _identityId Id of the identity
    /// @param _name The name of the identity
    function _generateAnchor(bytes32 _identityId, string memory _name) internal pure returns (address) {
        bytes32 attestationHash = keccak256(abi.encodePacked(_identityId, _name));

        return address(uint160(uint256(attestationHash)));
    }

    /// @notice Generates the identityId based on msg.sender
    /// @param _nonce Nonce used to generate identityId
    function _generateIdentityId(uint256 _nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_nonce, msg.sender));
    }
}
