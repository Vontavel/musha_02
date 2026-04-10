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
