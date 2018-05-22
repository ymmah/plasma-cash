pragma solidity ^0.4.22;

import 'openzeppelin-solidity/contracts/token/ERC721/ERC721Receiver.sol';
import 'openzeppelin-solidity/contracts/math/SafeMath.sol';
import './Cards.sol';

// Lib deps
import '../Libraries/Transaction/Transaction.sol';
import '../Libraries/ByteUtils.sol';
import '../Libraries/SparseMerkleTree.sol';

contract RootChain is ERC721Receiver {
    /*
     * Events
     */
    event Deposit(uint256 slot, uint256 depositBlockNumber, uint256 denomination, address indexed from);
    event ExitStarted(uint indexed slot, address indexed owner, uint created_at);
    event FinalizedExit(address  owner, uint256  uid);

    using SafeMath for uint256;
    using ERC721PlasmaRLP for bytes;
    using ERC721PlasmaRLP for ERC721PlasmaRLP.txData;

    using ECVerify for bytes32;

    using Transaction for bytes;
    using SparseMerkleTree for bytes32;

    /*
     * Storage
     */

    address public authority;

    // exits
    uint[] public exitSlots;
    mapping(uint256 => Exit) public exits;
    struct Exit {
        address owner;
        uint256 created_at;
    }

    // tracking of NFTs deposited in each slot
    uint public NUM_COINS;
    mapping (uint => NFT_UTXO) public coins; 
    struct NFT_UTXO {
        uint256 uid; // there are up to 2^256 cards, can probably make it less
        uint256 denomination; // an owner cannot own more than 256 of a card. Currently set to 1 always, subject to change once the token changes
        address owner; // who owns that nft
        bool canExit;
    }

    // child chain
    uint256 public childBlockInterval;
    uint256 public currentChildBlock;
    uint256 public currentDepositBlock;
    uint256 public lastParentBlock;
    struct childBlock {
        bytes32 root;
        uint256 created_at;
    }

    uint public depositCount;
    mapping(uint => childBlock) public childChain;
    mapping(address => uint256[]) public pendingWithdrawals; //  the pending cards to withdraw
    CryptoCards cryptoCards;

    /*
     * Modifiers
     */
    modifier isAuthority() {
        require(msg.sender == authority);
        _;
    }

    constructor () public{
        authority = msg.sender;

		childBlockInterval = 1000;
        currentChildBlock = childBlockInterval;
        currentDepositBlock = 1;
        lastParentBlock = block.number; // to ensure no chain reorgs

    }

    function setCryptoCards(CryptoCards _cryptoCards) isAuthority public {
        cryptoCards = _cryptoCards;
    }

    /// @param root 32 byte merkleRoot of ChildChain block
    /// @notice childChain blocks can only be submitted at most every 6 root chain blocks
    function submitBlock(bytes32 root)
        public
        isAuthority
    {
        // ensure finality on previous blocks before submitting another
        // require(block.number >= lastParentBlock.add(6)); // commented out while prototyping

        childChain[currentChildBlock] = childBlock({
            root: root,
            created_at: block.timestamp
        });

        currentChildBlock = currentChildBlock.add(childBlockInterval);
        currentDepositBlock = 1;
        lastParentBlock = block.number;
	}


    /// @dev Allows anyone to deposit funds into the Plasma chain, called when contract receives ERC721
    function deposit(address from, uint256 uid, uint256 denomination, bytes txBytes)
        private
    {
        ERC721PlasmaRLP.txData memory txData = txBytes.getTxData();
        // Verify that the transaction data sent matches the coin data from ERC721
        require(txData.slot == NUM_COINS);
        require(txData.denomination == denomination);
        require(txData.owner == from);
        require(txData.prevBlock == 0);

        // Update state "tree"
        coins[NUM_COINS] = NFT_UTXO({
                uid: uid, 
                denomination: denomination,
                owner: from, 
                canExit: false 
        });

        bytes32 txHash = keccak256(txBytes);
        uint256 depositBlockNumber = getDepositBlock();

        childChain[depositBlockNumber] = childBlock({
            root: txHash, // save signed transaction hash as root
            created_at: block.timestamp
        });

        currentDepositBlock = currentDepositBlock.add(1);
        emit Deposit(NUM_COINS, depositBlockNumber, denomination, from); // create a utxo at slot `NUM_COINS`

        NUM_COINS += 1;
    }

    function startExit(
        uint slot,
        bytes prevTxBytes, bytes exitingTxBytes, 
        bytes prevTxInclusionProof, bytes exitingTxInclusionProof, 
        // bytes sigs,
        uint prevTxIncBlock, uint exitingTxIncBlock) 
        external
    {
        // Different inclusion check depending on if we're exiting a deposit transaction or not
        if (exitingTxIncBlock % childBlockInterval != 0 ) { 
           require(
                checkDepositBlockInclusion(
                    exitingTxBytes, 
                    sigs, // for deposit blocks this is just a single sig
                    exitingTxIncBlock
                ),
                "Not included in deposit block"
            );
        } else {
            require(
                checkBlockInclusion(
                    prevTxBytes, exitingTxBytes,
                    prevTxInclusionProof, exitingTxInclusionProof,
                    sigs,
                    prevTxIncBlock, exitingTxIncBlock
                ), 
                "Not included in blocks"
            );
        }

        exitSlots.push(slot);
        exits[slot] = Exit({
            owner: msg.sender, 
            created_at: block.timestamp
        });

        emit ExitStarted(slot, msg.sender, block.timestamp);
    }

    function getSig(bytes sigs, uint i) public pure returns(bytes) {
        return ByteUtils.slice(sigs, 65 * i,  65);
    }

    function checkDepositBlockInclusion(
        bytes txBytes,
        bytes signature,
        uint txIncBlock
    )
         private 
         view 
         returns (bool) 
    {
        ERC721PlasmaRLP.txData memory txData = txBytes.getTxData();
        bytes32 txHash = keccak256(txBytes); 
        require(txHash.ecverify(signature, txData.owner), "Invalid sig");
        require(
            txHash == childChain[txIncBlock].root, 
            "Deposit Tx not included in block"
        );

        return true;
    }


    function checkBlockInclusion(
            bytes prevTxBytes, bytes exitingTxBytes,
            bytes prevTxInclusionProof, bytes exitingTxInclusionProof,
            bytes sigs,
            uint prevTxIncBlock, uint exitingTxIncBlock) 
            private
            view
            returns (bool)
    {
        ERC721PlasmaRLP.txData memory prevTxData = prevTxBytes.getTxData();
        ERC721PlasmaRLP.txData memory exitingTxData = exitingTxBytes.getTxData();

        bytes32 txHash = keccak256(exitingTxBytes);
        bytes32 root = childChain[exitingTxIncBlock].root;

        // TODO: Debug the requires.
        // require(txHash.ecverify(getSig(sigs, 1), prevTxData.owner), "Invalid sig");
        // require(exitingTxData.owner == msg.sender, "Invalid sender");
        /* 
        require(
            txHash.checkMembership(
                exitingTxData.slot, 
                root, 
                exitingTxInclusionProof
            ),
            "Exiting tx not included in claimed block"
        );

        bytes32 prevTxHash = keccak256(prevTxBytes);
        bytes32 prevRoot = childChain[prevTxIncBlock].root;

        if (prevTxIncBlock % childBlockInterval != 0 ) { 
            require(prevTxHash == prevRoot); // like in deposit block
        } else {
            require(
                prevTxHash.checkMembership(
                    prevTxData.slot,
                    prevRoot, 
                    prevTxInclusionProof
                ),
                "Previous tx not included in claimed block"
            );
        }
       */

        return true;
    }

    function finalizeExits() external {
        Exit memory currentExit;
        uint exitSlotsLength = exitSlots.length;
        uint slot;
        for (uint i = 0; i < exitSlotsLength; i++) { 
            slot = exitSlots[i];
            currentExit = exits[slot];

            // Process an exit only if it has matured and hasn't been challenged. Only checking date since a challenged exit will dissapear. < Commented out during Development > 
            // if ((block.timestamp - currentExit.created_at) > 7 days ) {
                // Change owner of coin at exit.slot and allow that coin to be exited
                coins[slot].owner = currentExit.owner;
                coins[slot].canExit = true;
                
                // delete the finalized exit
                delete exits[slot];
                delete exitSlots[i];

                emit FinalizedExit(currentExit.owner, slot);
            // }
        }
    }

    function challengeExit(uint slot) external {
        // perform validation
        delete exits[slot];    
        delete exitSlots[slot];
    }

    // Withdraw a UTXO that has been exited
    function withdraw(uint slot) external {
        require(coins[slot].owner == msg.sender, "You do not own that UTXO");
        require(coins[slot].canExit, "You cannot exit that coin!");
        cryptoCards.safeTransferFrom(address(this), msg.sender, coins[slot].uid);
    }

    function getDepositBlock() public view returns (uint256) {
        return currentChildBlock.sub(childBlockInterval).add(currentDepositBlock);
    }

    /// receiver for erc721 to trigger a deposit
    function onERC721Received(address _from, uint256 _uid, bytes _data) 
        public 
        returns(bytes4) 
    {
        require(msg.sender == address(cryptoCards)); // can only be called by the associated cryptocards contract. 
        deposit(_from, _uid, 1, _data);
        return ERC721_RECEIVED;
    }
}

