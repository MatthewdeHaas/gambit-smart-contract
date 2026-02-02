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
    uint256 maxBetParticipants;

    constructor(address _ctfAddress, address _usdcAddress, uint256 _maxBetParticipants) {
        ctf = IConditionalTokens(_ctfAddress);
        usdc = IERC20(_usdcAddress);
        oo = OptimisticOracleV3Interface(_oo); 
        defaultIdentifier = oo.defaultIdentifier();
        maxBetParticipants = _maxBetParticipants;
        usdc.approve(address(ctf), type(uint256).max);
    }

    // Enums for convenience/readability
    enum BetStatus { Accepting, Locked, Active, Resolved, Disupted, Cancelled }

   // Bet data
    struct Bet {
        address[] participants;
        uint numParticipants;
        uint256 amount;
        uint256 startTimeStamp;
        uint256 endTimeStamp;
        bytes32 conditionId;
        BetStatus status;
    }

    // Metadata tracker
    mapping(bytes32 => Bet) public bets;

    // Participant data
    mapping(bytes32 => mapping(address => bool)) isInvited;
    mapping(bytes32 => mapping(address => uint256)) participantProbability;
    mapping(bytes32 => mapping(address => address)) outcomeVote;

    // Global probability mappings for quick lookups
    mapping(bytes32 => mapping(uint256 => bool)) public probabilityExists;
    mapping(bytes32 => mapping(uint256 => bool)) public probilityTaken;

    // OO mapping
    mapping(bytes32 => bytes32) public assertionsToQuestions;

    // Cheap transactions sent over the blockchain to broadcast important events
    event BetCreated(bytes32 indexed questionId, address indexed creator, uint256 amount, indexed uint256 startTimeStamp, indexed uint256 endTimeStamp);
    event BetJoined(bytes32 indexed questionId, address indexed joiner, uint256 indexed probability);
    event BetStarted(bytes32 indexed questionId);
    event BetResolved(bytes indexed questionId, address indexed participant, BetPosition indexed outcome);
    event BetDisputed(bytes32 indexed, address indexed disputer);

    function createBet(bytes32 questionId, uint256 amount, uint256[] calldata probabilities, address[] calldata challengers, uint256 endTimeStamp) external {
        require(bets[questionId].startTimeStamp == 0, "Bet already exists!");
        require(amount > 0, "Amount must be a postive number!");
        require(endTimeStamp > block.timestamp, "Resolution date must be in the future!");
        require(challengers.length > 1 && challengers.length <= maxParticipants, "Invalid number of participants!");
        require(probabilities.length == challengers.length, "Incorrect number of probabilities specified!");
        uint256 probSum = 0;
        for (uint256 i = 0; i < probabilities.length; i++) {
            uint256 p = probabilities[i];

            require(p > 0 && p < 1e18, "Invalid probability");
            require(!probabilitytaken[questionId][p]);

            probabilityExists[questionId][p] = true;
                
            probSum += p;
        }
        require(probSum < 1e18, "Probabilities must sum to 1!"); 

        // Transfer the USDC from the creator's wallet (they need to call usdc.approve() first)
        usdc.transferFrom(msg.sender, address(this), amount);

        // Retrieve the bet struct from storage to save gas
        Bet storage bet = bets[questionId];
            
        // Add fields to the bet struct
        bet.numParticipants = challengers.length + 1;
        bet.amount = amount;
        bet.startTimeStamp = block.timestamp;
        bet.endTimeStamp = endTimeStamp;
        bet.status = BetStatus.Accepting;

        bet.participants.push(msg.sender); 

        uint256 creatorProb = 1e18 - probSum;
        participantProbability[questionId][msg.sender] = creatorProb;
        probabilityTaken[questionId][creatorProb] = true;

        outcomeVote[questionId][msg.sender] = address(0);

        // Add the participating and probability mappings 
        for (uint256 i = 0; i < challengers.length; i++) {
           isInvited[questionId][challengers[i]] = true;
           probabilityExists[questionId][probability[i]] = true;
        }

        emit BetCreated(questionId, msg.sender, amount, block.timestamp, endTimeStamp);
    }

    function joinBet(bytes32 questionId, uint256 probability) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Accepting, "Bet is already taken!");
        require(isInvited[questionId][msg.sender], "You are not able to join this bet!");
        require(participantProbability[questionId][msg.sender] == 0, "You cannot join a more than once!");
        require(probabilityExists[questionId][probability], "Invalid probability!");
        require(!probabilityTaken[questionId][probability], "Participant already claimed this probability!");

        uint256 creatorProb = participantProbability[questionId][msg.sender];
        uint256 joinAmount = (bet.amount * probability) / creatorProb;
   
        // Take money from the joiner
        usdc.transferFrom(msg.sender, address(this), joinAmount);

        // Update the bet status
        bet.participants.push(msg.sender);
        outcomeVote[questionId][msg.sender] = address(0);
        joinedBet[questionId][msg.sender] = true;

        participantProbability[questionId][msg.sender] = probability;
        probabilityTaken[questionId][probability] = true;

        // Change the status based on whether the bet is full
        if (bet.participants.length == bet.numParticipants) {
            _startBet(questionId);
        }
        emit BetJoined(questionId, msg.sender, probability);
    }

    function _startBet(bytes32 questionId) internal {
        Bet storage bet = bets[questionId];
        uint256 pot = (bet.amount * 1e18) / participantProbability[questionId][bet.participants[0]];
            
        // Prepare the condition
        ctf.prepareCondition(address(this), questionId, bet.numParticipants);
        bytes32 conditionId = ctf.getConditionId(msg.sender, questionId, participants.length) 
        bet.conditionId = conditionId;

        // Assign non-overlapping indices to the conditional tokens
        uint256 numParticipants = bet.numParticipants;
        uint256[] memory partition = new uint256[](n);
        for (uint256 i = 0; i < numParticipants; i++) {
            partition[i] = 1 << i;
        }

        // Mint the tokens
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, pot);

        // Send the participants their respective conditional tokens
        for (uint i = 0; i < numParticipants; i++) {
            bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, 1 << i);
            uint256 conditionalTokenId = uint256(keccak256(abi.encodePacked(address(usdc), collectionId)))
            ctf.safeTransferFrom(address(this), participants[i], conditionalTokenId, pot, "");
        }

        bet.status = BetStatus.Active;
        emit BetStarted(questionId); 
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

