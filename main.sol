// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Musha V2 — sealed bonds with server-grade defaults.
 * Differs from V1: monotonic IDs, reentrancy lock, min lock span, max bond cap.
 * Warden may pause; owner sweeps tolls. No literals for EOAs.
 * Constructor takes no args; min lock span is DEFAULT_MIN_DWELL_SEC (Remix-friendly).
 */
contract MushaV2 {
    error V2_SealUnknown(uint256 sealId);
    error V2_SealVoided();
    error V2_SealNotMature(uint64 opensAt);
    error V2_KeyMismatch();
    error V2_TollShort(uint256 got, uint256 need);
    error V2_BondOutOfRange(uint256 bond);
    error V2_CommitmentEmpty();
    error V2_CircuitOpen();
    error V2_AccessDenied();
    error V2_WardenZero();
    error V2_PayoutReverted();
    error V2_Reentrant();
    error V2_AnnulTooLate(uint64 opensAt);

    event SealCast(uint256 indexed sealId, address indexed smith, uint64 opensAt, uint256 bond, bytes32 veil);
    event SealSplit(uint256 indexed sealId, address indexed opener, bytes32 proofHash);
    event SealAnnulled(uint256 indexed sealId, address indexed smith);
    event WardenRotated(address indexed prior, address indexed next);
    event CircuitFlipped(bool halted);
    event TollsRouted(address indexed sink, uint256 weiMoved);

    struct Seal {
        address smith;
        uint64 opensAt;
        uint96 bond;
        bytes32 veil;
        bool annulled;
    }

    address public immutable sovereign;
    address public warden;
    bool public halted;

    uint256 public constant TOLL_WEI = 188_442_919_000_000;
    uint256 public constant MIN_BOND_WEI = 1_500_000_000_000_000;
    uint256 public constant MAX_BOND_WEI = 888 ether;
    /// @dev Minimum seconds between cast and opensAt; baked in so Remix deploy needs no constructor input.
    uint64 public constant DEFAULT_MIN_DWELL_SEC = 4_799;
    uint64 public immutable minDwell;

    uint256 private _gate;
    uint256 public nextSealId;
    uint256 public tollChest;
    mapping(uint256 => Seal) private _seals;
