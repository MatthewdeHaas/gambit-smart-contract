// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IConditionalTokens.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "./console.sol";


contract Gambit is ERC1155Holder {

    IConditionalTokens public ctf;
    IERC20 public usdc;

    constructor(address _ctfAddress, address _usdcAddress) {
        ctf = IConditionalTokens(_ctfAddress);
        usdc = IERC20(_usdcAddress);
    }

    enum BetStatus { Open, Challenged, Resolved, Cancelled }

    struct Bet {
        address creator;
        address challenger;
        uint256 amount;
        uint256 probability;
        uint256 startTimeStamp;
        uint256 endTimeStamp;
        bytes32 conditionId;
        BetStatus status;
    }

    // This tells the blockchain how to format the log for this transaction
    event BetCreated(bytes32 indexed questionId, address indexed creator, uint256 amount, uint256 endTimeStamp);

    mapping(bytes32 => Bet) public bets;

    function createBet(uint256 amount, uint256 probability, bytes32 questionId, uint256 endTimeStamp) external {
        // Validate input
        require(probability > 0 && probability < 10**18, "Invalid probability");
        require(amount > 0, "Amount must be a postive number!");
        require(endTimeStamp > block.timestamp, "End Timestamp must be in the future.");
     
        // Prepare the condition
        address oracle = msg.sender; 
        uint256 outcome_slot_count = 2;
        ctf.prepareCondition(oracle, questionId, outcome_slot_count);
        bytes32 conditionId = keccak256(
            abi.encodePacked(
                oracle,
                questionId, 
                uint256(outcome_slot_count)
            )
        );

        // Transfer the USDC from the creator's wallet (they need to call usdc.approve() first)
        usdc.transferFrom(msg.sender, address(this), amount); 

        // Put the bet in storage/on the blockchain
        bets[questionId] = Bet({
            creator: msg.sender,
            challenger: address(0),
            amount: amount,
            probability: probability,
            startTimeStamp: block.timestamp,
            endTimeStamp: endTimeStamp,
            conditionId: conditionId,
            status: BetStatus.Open
        });

        emit BetCreated(questionId, msg.sender, amount, endTimeStamp);
    }

    function challengeBet(bytes32 questionId) external {
        Bet storage bet = bets[questionId];
        require(bet.status == BetStatus.Open, "Bet is already taken!");
        require(bet.creator != address(0), "Bet does not exist");
        require(bet.conditionId != bytes32(0), "Condition ID is empty");

        uint256 pot = (bet.amount * 10**18) / bet.probability;
        uint256 challengerAmount = pot - bet.amount;
        
        // Take money from the joiner
        usdc.transferFrom(msg.sender, address(this), challengerAmount);

        // Allow the CTF to take the pot as collateral
        usdc.approve(address(ctf), pot);

        // Split the position
        uint[] memory partition = new uint[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO
        ctf.splitPosition(address(usdc), bytes32(0), bet.conditionId, partition, pot);

        // Give the tokens to the users
        bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), bet.conditionId, 1);
        bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), bet.conditionId, 2); 
        uint256 yesTokenId = uint256(keccak256(abi.encodePacked(address(usdc), yesCollectionId)));
        uint256 noTokenId = uint256(keccak256(abi.encodePacked(address(usdc), noCollectionId)));

        // Send YES to Creator, NO to Challenger
        ctf.safeTransferFrom(address(this), bet.creator, yesTokenId, pot, "");
        ctf.safeTransferFrom(address(this), msg.sender, noTokenId, pot, "");

        bet.status = BetStatus.Challenged;
        bet.challenger = msg.sender;
    }

}

