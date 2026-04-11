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

    modifier onlySovereign() {
        if (msg.sender != sovereign) revert V2_AccessDenied();
        _;
    }

    modifier onlyWardenOrSovereign() {
        if (msg.sender != sovereign && msg.sender != warden) revert V2_AccessDenied();
        _;
    }

    modifier whenLive() {
        if (halted) revert V2_CircuitOpen();
        _;
    }

    modifier nonReentrant() {
        if (_gate == 2) revert V2_Reentrant();
        _gate = 2;
        _;
        _gate = 1;
    }

    constructor() {
        sovereign = msg.sender;
        warden = msg.sender;
        minDwell = DEFAULT_MIN_DWELL_SEC;
        _gate = 1;
        emit WardenRotated(address(0), msg.sender);
    }

    receive() external payable {
        revert("MushaV2: no direct ETH");
    }

    fallback() external payable {
        revert("MushaV2: bad call");
    }

    /**
     * Cast a new seal. Returns sealId. veil = keccak256(abi.encodePacked(nonce, beneficiary)).
     * opensAt must be >= block.timestamp + minDwell.
     */
    function castSeal(bytes32 veil, uint64 opensAt) external payable whenLive returns (uint256 sealId) {
        if (veil == bytes32(0)) revert V2_CommitmentEmpty();
        if (opensAt < block.timestamp + minDwell) revert V2_SealNotMature(uint64(block.timestamp + minDwell));

        if (msg.value < TOLL_WEI + MIN_BOND_WEI) revert V2_TollShort(msg.value, TOLL_WEI + MIN_BOND_WEI);

        uint256 bond = msg.value - TOLL_WEI;
        if (bond < MIN_BOND_WEI || bond > MAX_BOND_WEI) revert V2_BondOutOfRange(bond);

        tollChest += TOLL_WEI;

        sealId = nextSealId++;
        _seals[sealId] = Seal({
            smith: msg.sender,
            opensAt: opensAt,
            bond: uint96(bond),
            veil: veil,
            annulled: false
        });

        emit SealCast(sealId, msg.sender, opensAt, bond, veil);
    }

    /**
     * Split seal after opensAt: nonce proves knowledge; beneficiary must be msg.sender.
     */
    function splitSeal(uint256 sealId, bytes32 nonce) external whenLive nonReentrant {
        Seal storage s = _seals[sealId];
        if (s.smith == address(0)) revert V2_SealUnknown(sealId);
        if (s.annulled) revert V2_SealVoided();
        if (block.timestamp < s.opensAt) revert V2_SealNotMature(s.opensAt);

        bytes32 h = keccak256(abi.encodePacked(nonce, msg.sender));
        if (h != s.veil) revert V2_KeyMismatch();

        s.annulled = true;

        uint256 out = uint256(s.bond);
        (bool ok, ) = msg.sender.call{value: out}("");
        if (!ok) revert V2_PayoutReverted();

        emit SealSplit(sealId, msg.sender, keccak256(abi.encodePacked(nonce)));
    }

    /** Smith may annul before maturity; toll is not refunded. */
    function annulSeal(uint256 sealId) external whenLive nonReentrant {
        Seal storage s = _seals[sealId];
        if (s.smith != msg.sender) revert V2_AccessDenied();
        if (s.smith == address(0)) revert V2_SealUnknown(sealId);
        if (s.annulled) revert V2_SealVoided();
        if (block.timestamp >= s.opensAt) revert V2_AnnulTooLate(s.opensAt);

        s.annulled = true;

        uint256 out = uint256(s.bond);
        (bool ok, ) = msg.sender.call{value: out}("");
        if (!ok) revert V2_PayoutReverted();

        emit SealAnnulled(sealId, msg.sender);
    }

    function rotateWarden(address next) external onlySovereign {
        if (next == address(0)) revert V2_WardenZero();
        address prior = warden;
        warden = next;
