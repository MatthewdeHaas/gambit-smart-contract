// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IConditionalTokens.sol";
import "./IOOV3.sol";
import "./vendor/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./vendor/@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";


contract Gambit is ERC1155Holder {

    // Contract objects used throughout the contract, defined when the object is created
    IConditionalTokens public ctf;
    IERC20 public usdc;
    IOOV3 public oo;
    bytes32 public immutable defaultIdentifier;
    uint256 maxBetParticipants;

    constructor(address _ctfAddress, address _usdcAddress, address _ooAddress, uint256 _maxBetParticipants) {
        ctf = IConditionalTokens(_ctfAddress);
        usdc = IERC20(_usdcAddress);
        oo = IOOV3(_ooAddress); 
        maxBetParticipants = _maxBetParticipants;
    }

    // Enums for convenience/readability
    enum BetStatus { Accepting, Active, Resolving, Resolved, Disputed, Escalated, Cancelled }

   // Bet data
    struct Bet {
        address[] participants;
        uint numParticipants;
        uint256 amount;
        uint256 startTimeStamp;
        uint256 endTimeStamp;
        bytes32 questionId;
        bytes32 conditionId;
        BetStatus status;
        uint256 voteCount;
    }

    function getParticipants(bytes32 _questionId) public view returns (address[] memory) {
        return bets[_questionId].participants;
    }

    function setupApproval() external {
        usdc.approve(address(ctf), type(uint256).max);
    }

    // Metadata tracker
    mapping(bytes32 => Bet) public bets;

    // Participant data
    mapping(bytes32 => mapping(address => uint256)) public participantIndex;
    mapping(bytes32 => mapping(address => bool)) isInvited;
    mapping(bytes32 => mapping(address => uint256)) public participantProbability;
    mapping(bytes32 => mapping(address => address)) outcomeVote;
    mapping(bytes32 => mapping(address => uint256)) outcomeVoteCount; // number of votes an address has
    mapping(bytes32 => address) leadingCandidate; // The address of the leading candidate
    mapping(bytes32 => address) assertionWinner;

    // Global probability mappings for quick lookups
    mapping(bytes32 => mapping(uint256 => bool)) public probabilityExists;
    mapping(bytes32 => mapping(uint256 => bool)) public probabilityTaken;

    // OO mapping
    mapping(bytes32 => bytes32) public assertionToQuestion;

    // Cheap transactions sent over the blockchain to broadcast important events
    event BetCreated(bytes32 indexed questionId, uint256 amount, uint256 indexed endTimeStamp);
    event BetJoined(bytes32 indexed questionId, address indexed joiner, uint256 indexed probability);
    event BetStarted(bytes32 indexed questionId);
    event BetResolved(bytes32 indexed questionId, address indexed winner);
    event BetDisputed(bytes32 indexed questionId);
    event BetEscalated(bytes32 indexed questionId, address indexed escalator);

    function createBet(bytes32 questionId, uint256 amount, address[] calldata challengers, uint256[] calldata challengerProbabilities, uint256 endTimeStamp) external {
        require(bets[questionId].startTimeStamp == 0, "Bet already exists!");
        require(amount > 0, "Amount must be a postive number!");
        require(endTimeStamp > block.timestamp, "Resolution date must be in the future!");
        require(challengers.length >= 1 && challengers.length <= maxBetParticipants - 1, "Invalid number of participants!");
        require(challengerProbabilities.length == challengers.length, "Incorrect number of probabilities specified!");
        uint256 probSum = 0;
        for (uint256 i = 0; i < challengerProbabilities.length; i++) {
            uint256 p = challengerProbabilities[i];

            require(p > 0 && p < 1e18, "Invalid probability");
            require(!probabilityTaken[questionId][p]);

            probabilityExists[questionId][p] = true;
                
            probSum += p;
        }
        require(probSum < 1e18, "Probabilities must sum to 1!"); 

        // Transfer the USDC from the creator's wallet
        // usdc.approve(address(ctf), amount);
        usdc.transferFrom(msg.sender, address(this), amount);

        // Retrieve the bet struct from storage to save gas
        Bet storage bet = bets[questionId];
            
        // Add fields to the bet struct
        bet.participants.push(msg.sender); 
        bet.numParticipants = challengers.length + 1;
        bet.amount = amount;
        bet.startTimeStamp = block.timestamp;
        bet.endTimeStamp = endTimeStamp;
        bet.status = BetStatus.Accepting;
        bet.voteCount = 0;
        bet.questionId = questionId;

        uint256 creatorProb = 1e18 - probSum;
        participantIndex[questionId][msg.sender] = 1; // Use 1-based indexing so the empty value (zero) is not confused with the creator
        participantProbability[questionId][msg.sender] = creatorProb;
        probabilityTaken[questionId][creatorProb] = true;

        outcomeVote[questionId][msg.sender] = address(0);

        // Add the invitation and probability mappings 
        for (uint256 i = 0; i < challengers.length; i++) {
           isInvited[questionId][challengers[i]] = true;
           probabilityExists[questionId][challengerProbabilities[i]] = true;
        }

        emit BetCreated(questionId, amount, endTimeStamp);
    }

    function joinBet(bytes32 questionId, uint256 probability) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Accepting, "Bet is already taken!");
        require(isInvited[questionId][msg.sender], "You are not able to join this bet!");
        require(participantProbability[questionId][msg.sender] == 0, "You cannot join a more than once!");
        require(probabilityExists[questionId][probability], "Invalid probability!");
        require(!probabilityTaken[questionId][probability], "Participant already claimed this probability!");

        uint256 creatorProb = participantProbability[questionId][bet.participants[0]];
        uint256 joinAmount = (bet.amount * probability) / creatorProb;
   
        // Take money from the joiner
        // usdc.approve(, joinAmount);
        usdc.transferFrom(msg.sender, address(this), joinAmount);

        // Update the bet status
        bet.participants.push(msg.sender);
        participantIndex[questionId][msg.sender] = bet.participants.length;
        outcomeVote[questionId][msg.sender] = address(0);

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
        uint256 numOutcomeSlots = bet.numParticipants;
        ctf.prepareCondition(address(this), questionId, numOutcomeSlots);
        bytes32 conditionId = ctf.getConditionId(address(this), questionId, numOutcomeSlots); 
        bet.conditionId = conditionId;

        // Assign non-overlapping indices to the conditional tokens
        uint256 numParticipants = bet.numParticipants;
        uint256[] memory partition = new uint256[](numParticipants);
        for (uint256 i = 0; i < numParticipants; i++) {
            partition[i] = 1 << i;
        }

        // Mint the tokens
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, pot);

        // Send the participants their respective conditional tokens
        for (uint i = 0; i < numParticipants; i++) {
            bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, 1 << i);
            uint256 conditionalTokenId = uint256(keccak256(abi.encodePacked(address(usdc), collectionId)));
            ctf.safeTransferFrom(address(this), bet.participants[i], conditionalTokenId, pot, "");
        }

        bet.status = BetStatus.Active;
        emit BetStarted(questionId); 
    }

    function voteOnOutcome(bytes32 questionId, address vote) external {
        Bet storage bet = bets[questionId];
        // Storage costs relatively more gas, so only store if you need to
        if (block.timestamp >= bet.endTimeStamp && bet.status == BetStatus.Active) {
            bet.status = BetStatus.Resolving;
        }
        require(bet.status == BetStatus.Resolving, "Bet is not currently being resolved!");
        require(outcomeVote[questionId][msg.sender] == address(0), "You cannot vote twice!");
        require(participantProbability[questionId][vote] > 0, "User voted for was not part of the bet!");
        
        // Record the user's vote
        outcomeVote[questionId][msg.sender] = vote;
        outcomeVoteCount[questionId][vote]++;
        bet.voteCount++;

        // Check if the leading candidate changed
        address leader = leadingCandidate[questionId];
        if (outcomeVoteCount[questionId][vote] > outcomeVoteCount[questionId][leader]) {
            leadingCandidate[questionId] = vote;
            leader = vote;
        }

        uint256 leaderVotes = outcomeVoteCount[questionId][leader];
        uint256 remainingVotes = bet.numParticipants - bet.voteCount;

        // If > 50% of votes go to one address, that address wins
        if (2 * leaderVotes > bet.numParticipants) {
            _valueTokens(questionId, bet, leader);
        } else if (2 * (leaderVotes + remainingVotes) <= bet.numParticipants) { // If the leader cannot reach 50%, raise a dispute
            bet.status = BetStatus.Disputed;
            emit BetDisputed(questionId);
        }
    }

    function _valueTokens(bytes32 questionId, Bet storage bet, address winner) internal {
        // Recall that this mapping is 1-based to avoid confusing index zero and an empty value
        uint256 winnerIndex = participantIndex[questionId][winner] - 1;
        require(winnerIndex < bet.numParticipants, "Winner not in the participants array!");

        
        uint256[] memory payouts = new uint256[](bet.numParticipants);
        payouts[winnerIndex] = 1;
        ctf.reportPayouts(questionId, payouts);

        bet.status = BetStatus.Resolved;
        emit BetResolved(questionId, winner);
    }

    function escalateToUMA(bytes32 questionId, address allegedWinner) external {
        Bet storage bet = bets[questionId];
        require(participantProbability[questionId][msg.sender] > 0, "Not involed in the bet!");

        // Transfer the bond for escalating
        uint256 bond = oo.getMinimumBond(address(usdc));
        usdc.transferFrom(msg.sender, address(this), bond);

        // Define the question for the oracle
        bytes memory ancillaryData = abi.encodePacked(
                "As of timestamp ", block.timestamp, 
                ", who won the bet with questionId: ", questionId
        );

        // Ask the oracle
        bytes32 assertionId = oo.assertTruth(
            ancillaryData,
            msg.sender,        // Disputer (receives bond back if correct)
            address(this),     // Callback recipient
            address(0),        // No sovereign aid
            7200,              // Liveness period (2 hours)
            usdc,     // Bond currency
            bond,
            "ASSERT_TRUTH",    // Standard identifier
            0                  // No reward
        );

        assertionToQuestion[assertionId] = questionId;
        // Used to determine who gets the tokens
        assertionWinner[assertionId] = allegedWinner;
        bet.status = BetStatus.Escalated;
        emit BetEscalated(questionId, msg.sender);
    }

    // Called by OO when the assertion is settled
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        require(msg.sender == address(oo), "Only OO can hit the callback!");
        bytes32 questionId = assertionToQuestion[assertionId];
        Bet storage bet = bets[questionId];
 
        if (assertedTruthfully) {
            _valueTokens(questionId, bet, assertionWinner[assertionId]);
        } else {
            bet.status = BetStatus.Disputed;
            assertionWinner[assertionId] = address(0);
        }
    }

}

