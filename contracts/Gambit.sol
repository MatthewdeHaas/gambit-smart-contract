// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IConditionalTokens.sol";
import "./console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";


contract Gambit is ERC1155Holder {

    // Contract objects used throughout the contract, defined when the object is created
    IConditionalTokens public ctf;
    IERC20 public usdc;
    OptimisticOracleV3Interface public immutable oo;
    bytes32 public immutable defaultIdentifier;

    constructor(address _ctfAddress, address _usdcAddress) {
        ctf = IConditionalTokens(_ctfAddress);
        usdc = IERC20(_usdcAddress);
        oo = OptimisticOracleV3Interface(_oo); 
        defaultIdentifier = oo.defaultIdentifier();
    }

    // Enums for convenience/readability
    enum BetStatus { Open, Challenged, Ongoing, Resolved, Disupted, Cancelled }
    enum BetPosition { Undecided, For, Against }

    // Bet data
    struct Bet {
        address creator;
        address challenger;
        uint256 amount;
        uint256 probability;
        uint256 startTimeStamp;
        uint256 endTimeStamp;
        bytes32 conditionId;
        BetStatus status;
        BetPosition creatorPosition;
        BetPosition challengerPosition;
    }

    // Cheap transactions sent over the blockchain to broadcast important events
    event BetCreated(bytes32 indexed questionId, address indexed creator, uint256 amount, uint256 endTimeStamp);
    event BetChallenged(bytes32 indexed questionId, address indexed challenger);
    event BetConfirmed(bytes32 indexed questionId, address indexed creator, bool indexed accepted);
    event BetResolved(bytes indexed questionId, address indexed participant, BetPosition indexed outcome);
    event BetDisputed(bytes32 indexed, address indexed disputer);

    // Mapping (dictionary) with key questionId and value Bet struct
    mapping(bytes32 => Bet) public bets;
    mapping(bytes32 => bytes32) public assertionsToQuestions;

    function createBet(uint256 amount, uint256 probability, bytes32 questionId, uint256 endTimeStamp) external {
        require(probability > 0 && probability < 10**18, "Invalid probability");
        require(amount > 0, "Amount must be a postive number!");
        require(endTimeStamp > block.timestamp, "End Timestamp must be in the future.");
     
        // Prepare the condition
        address oracle = msg.sender; 
        uint256 outcome_slot_count = 2;
        ctf.prepareCondition(oracle, questionId, outcome_slot_count);
        // Probably should use the built-in function instead of computing it directly
        bytes32 conditionId = keccak256(abi.encodePacked(oracle, questionId, uint256(outcome_slot_count)));

        // Transfer the USDC from the creator's wallet (they need to call usdc.approve() first)
        usdc.transferFrom(msg.sender, address(this), amount); 

        // Put the bet on the blockchain
        bets[questionId] = Bet({
            creator: msg.sender,
            challenger: address(0),
            amount: amount,
            probability: probability,
            startTimeStamp: block.timestamp,
            endTimeStamp: endTimeStamp,
            conditionId: conditionId,
            status: BetStatus.Open,
            creatorPosition: false,
            challengerPosition: false
        });

        emit BetCreated(questionId, msg.sender, amount, endTimeStamp);
    }

    function challengeBet(bytes32 questionId) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Open, "Bet is already taken!");

        uint256 pot = (bet.amount * 10**18) / bet.probability;
        uint256 challengerAmount = pot - bet.amount;
        
        // Take money from the joiner
        usdc.transferFrom(msg.sender, address(this), challengerAmount);

        // Update the bet status
        bet.status = BetStatus.Challenged;
        bet.challenger = msg.sender;
        emit BetChallenged(questionId, msg.sender);
    }

    function confirmChallenge(bytes32 questionId, bool accepted) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Challenged, "Bet has not been challenged or has already been confirmed!");
        require(msg.sender == bet.creator, "A bet can only be confirmed by its creator!");

        uint256 pot = (bet.amount * 10**18) / bet.probability;

        if (accepted) {
            // Allow the CTF to take the pot as collateral
            usdc.approve(address(ctf), pot);

            // Split the collateralized tokens
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1; // YES
            partition[1] = 2; // NO
            ctf.splitPosition(address(usdc), bytes32(0), bet.conditionId, partition, pot);

            // Mint the tokens
            bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), bet.conditionId, 1);
            bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), bet.conditionId, 2); 
            uint256 yesTokenId = uint256(keccak256(abi.encodePacked(address(usdc), yesCollectionId)));
            uint256 noTokenId = uint256(keccak256(abi.encodePacked(address(usdc), noCollectionId)));

            // Send YES to Creator, NO to Challenger
            ctf.safeTransferFrom(address(this), bet.creator, yesTokenId, pot, "");
            ctf.safeTransferFrom(address(this), bet.challenger, noTokenId, pot, "");

            bet.status = BetStatus.Ongoing;
        } else {
            // Refund the challenger
            uint256 challengerAmount = pot - bet.amount;
            usdc.transfer(bet.challenger, challengerAmount);

            // Revert the bet back to its original initial state
            bet.status = BetStatus.Open;
            bet.challenger = address(0);
        }

        emit BetConfirmed(questionId, msg.sender, accepted); 
    }

    // Users will send their settlement direction here
    // If they agree, money is sent to the winner
    // If there is a conflict, use the UMA Optimistic Oracle as a court of appeal
    function settleBet(bytes32 questionId, BetPosition position) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Ongoing, "Bet is not live anymore!");    
        require(block.timestamp > bet.endTimeStamp, "Bet has not reached its end date yet!");
        require(msg.sender == bet.creator || msg.sender == bet.challenger, "Only the involved parties can settle!");
        require(
            (msg.sender == bet.creator && bet.creatorPosition != BetPosition.Undecided) ||
            (msg.sender == bet.challenger && bet.challengerPosition != BetPosition.Undecided), 
            "Aready took a position!"
        );
        require(position == BetPosition.For || position == BetPosiiton.Against, "Provided position is invalid!");

        // Update the sender's position
        if (msg.sender == bet.creator) {
            bet.creatorPosition = position;
        } else {
            bet.challengerPosition = position;
        }

        // Both parties have taken a position
        if (bet.creatorPostion != BetPosition.Undecided && bet.challengerPosition != BetPosition.Undecided) {

            // Both parties have agreed on the matter
            if (bet.creatorPosition == bet.challengerPosition) {
                uint256 memory payout = new uint256[](2);

                // Value the conditional tokens based on the agreed upon resolution
                payout[0] = bet.creatorPosition == BetPosition.For ? 1 : 0;
                payout[1] = 1 - payout[0];

                // Report the new value of the tokens to the CTF
                ctf.reportPayouts(questionId, payout);   

                bet.status == BetStatus.Resolved;
                emit BetResolved(questionId, msg.sender, bet.creatorPosition);
            } else { // Conflict
                bet.status = BetStatus.Disputed;    
                emit BetDisputed(questionId, msg.sender);
            }
        }
    }

    function escalateToUMA(bytes32 questionId, BetPosition allegedWinningPosition) external payable {
        Bet storage bet = bets[questionId];
        require(allegedWinningPosition != BetPosition.Undecided, "Cannot escalate an undecided outcome!")
        require(msg.sender == bet.creator || msg.sender == bet.challenger, "Cannot escalate  on behalf of an involved party!");
        require(bet.creatorPosition != bet.challengerPosiiton, "Cannot escalate an non-conflicting outcome!");

        // Transfer the bond for escalating
        uint256 bond = oo.getMinimumBond(address(usdc));
        usdc.transfer(msg.sender, address(this), bond)

        // Define the question for the oracle
        bytes memory ancillaryData = abi.encodePacked("Did ", allegedWinningPosition == BetPosition.For ? "Creator" : "Challenger", " win?");

        // Ask the oracle
        oo.assertTruth(
            ancillaryData,
            msg.sender,
            address(this),
            address(0),
            7200,
            address(usdc),
            bond,
            identifier,
            0
        );
    }

    // Called by OO when the assertion is settled
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo), "Only OO can hit the callback!");

        bytes32 questionId = assertionsToQuestions[assertionId];
        Bet storage bet = bets[questionId];

 
        // Either do the opposite, or just reject the claim and leave as disputed
        if (assertedTruthfully) {
            _finalizeSettlementConflict(questionId, bet.claimedWinner);
        } else {
            continue;
        }
    }

    function _finalizeSettlement(bytes32 questionId, BetPosition confirmedWinningPosition) private {
        require(msg.sender == address(this), "Only contract can finalize a settlement!");
        require(confirmedWinningPosition != BetPosition.Undecided, "Invalid winning position!");
    }

}

