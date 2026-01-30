// contracts/IConditionalTokens.sol
// Replace the whole file with this to stop the import errors
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external view returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint indexSet) external view returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);
    function splitPosition(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] calldata partition, uint256 amount) external;
    function reportPayouts(bytes32 questionId, uint[] calldata payouts) external;
    function redeemPositions(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint[] calldata indexSets) external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
}
