// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface imports
import { IFleetOrderBook } from "./interfaces/IFleetOrderBook.sol";
import { IFleetOperatorBook } from "./interfaces/IFleetOperatorBook.sol";

/// @dev OpenZeppelin utils imports
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev OpenZeppelin access imports
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


/// @title 3wb.club fleet order yield V1.1
/// @notice Manages yield for fractional and full investments in 3-wheelers
/// @author geeloko.eth
/// 
/// @dev Role-based Access Control System:
/// - DEFAULT_ADMIN_ROLE: Can grant/revoke all other roles, highest privilege
/// - SUPER_ADMIN_ROLE: Can pause/unpause, set prices, max orders, add/remove ERC20s, update fleet status
/// - COMPLIANCE_ROLE: Can set compliance status for users
/// - WITHDRAWAL_ROLE: Can withdraw sales from the contract
/// 
/// @dev Security Benefits:
/// - Reduces risk of compromising the deployer wallet
/// - Allows delegation of specific functions to different admin addresses
/// - Provides granular control over different aspects of the contract
/// - Enables multi-signature or DAO governance for critical functions



contract FleetOrderYield is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role definitions
    bytes32 public constant SUPER_ADMIN_ROLE = keccak256("SUPER_ADMIN_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant WITHDRAWAL_ROLE = keccak256("WITHDRAWAL_ROLE");

    

    /// @notice The fleet order book contract
    IFleetOrderBook public fleetOrderBookContract;
    /// @notice The fleet operator book contract
    IFleetOperatorBook public fleetOperatorBookContract;
    /// @notice The yield token for the fleet order yield contract.
    IERC20 public yieldToken;
    /// @notice The fleet management service fee wallet for the fleet order yield contract.
    address public fleetManagementServiceFeeWallet;



    /// @notice State constants - each state is a power of 2 (bit position)
    uint256 constant SHIPPED = 1 << 0;      // 000001
    uint256 constant ARRIVED = 1 << 1;      // 000010
    uint256 constant CLEARED = 1 << 2;      // 000100
    uint256 constant REGISTERED = 1 << 3;   // 001000
    uint256 constant ASSIGNED = 1 << 4;     // 010000
    uint256 constant TRANSFERRED = 1 << 5;  // 100000


    /// @notice Mapping to store the price and inital value of each 3-wheeler fleet order
    mapping(uint256 => uint256) private fleetPaymentsDistributed;

    /// @notice Mapping to store the IRL fulfillment state of each 3-wheeler fleet order
    mapping(uint256 => uint256) private fleetOrderStatus;

    /// @notice Mapping to store the operator of each 3-wheeler fleet order
    mapping(uint256 => address[]) private fleetOperators;
    /// @notice Mapping to store the operator of each 3-wheeler fleet order
    mapping(address => uint256[]) private fleetOperated;
    /// @notice tracking fleet order index for each operator
    mapping(address => mapping(uint256 => uint256)) private fleetOperatedIndex;
    /// @notice tracking operators index for each fleet order
    mapping(uint256 => mapping(address => uint256)) private fleetOperatorsIndex;

    /// @notice Mapping to store the vehicle identification number for each 3-wheeler fleet order
    mapping(uint256 => string) private fleetVehicleIdentificationNumberPerOrder;
    /// @notice Mapping to store the license plate number for each 3-wheeler fleet order
    mapping(uint256 => string) private fleetLicensePlateNumberPerOrder;
    
    /// @notice Mapping to store the tracking of each 3-wheeler fleet order per container
    mapping(uint256 => string) private trackingPerContainer;


    /// @notice Event emitted when a fleet order status changes.
    event FleetOrderStatusChanged(uint256 indexed id, uint256 status);
    /// @notice Event emitted when the fleet weekly installment is paid
    event FleetWeeklyInstallmentPaid(address indexed payee, uint256 indexed id, uint256 indexed installment, uint256 amount);
    /// @notice Event emitted when the fleet owner shares dividend is distributed
    event FleetOwnerSharesDividend(uint256 indexed id, address indexed fleetOwner, uint256 amount);
    /// @notice Event emitted when the fleet owners yield is distributed
    event FleetOwnersYieldDistributed(uint256 indexed installment, uint256 indexed id, address[] indexed fleetOwners, uint256 amount);
    /// @notice Event emitted when fleet sales are withdrawn.
    event FleetManagementServiceFeeWithdrawn(address indexed token, address indexed to, uint256 amount);
    /// @notice Event emitted when a fleet operator is assigned
    event FleetOperatorAssigned(address indexed operator, uint256 indexed id);



    /// @notice Thrown when the id is Zero
    error InvalidId();
    /// @notice Thrown when the id does not exist
    error IdDoesNotExist();
    /// @notice Thrown when the token address is invalid
    error InvalidAddress();
    /// @notice Thrown when the token address is already set
    error TokenAlreadySet();
    /// @notice Thrown when the user does not have enough tokens
    error NotEnoughTokens();
    /// @notice Thrown when the amount is invalid
    error PaidFullAmount();
    /// @notice Thrown when the status is invalid
    error InvalidStatus();
    /// @notice Thrown when the amount is invalid
    error InvalidAmount();
    /// @notice Thrown when the operator is not assigned
    error OperatorNotAssigned();
    /// @notice Thrown when the state transition is invalid
    error InvalidStateTransition();
    /// @notice Thrown when the ids are duplicate
    error DuplicateIds();
    /// @notice Thrown when the bulk update limit is exceeded
    error BulkUpdateLimitExceeded();
    /// @notice Thrown when the max fleet order per container is not reached
    error MaxFleetOrderPerContainerNotReached();


    constructor() AccessControl() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SUPER_ADMIN_ROLE, msg.sender);
    }


    /// @notice Override supportsInterface to handle multiple inheritance
    /// @param interfaceId The interface ID to check
    /// @return bool True if the interface is supported
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl) returns (bool) {
        return AccessControl.supportsInterface(interfaceId);
    }


    /// @notice Set the yield token for the fleet order yield contract.
    /// @param _yieldToken The address of the yield token.
    function setYieldToken(address _yieldToken) external onlyRole(SUPER_ADMIN_ROLE) {
        if (_yieldToken == address(0)) revert InvalidAddress();
        if (_yieldToken == address(yieldToken)) revert TokenAlreadySet();

        yieldToken = IERC20(_yieldToken);
    }


    /// @notice Set the fleet order book contract for the fleet order yield contract.
    /// @param _fleetOrderBookContract The address of the fleet order book contract.
    function setFleetOrderBookContract(address _fleetOrderBookContract) external onlyRole(SUPER_ADMIN_ROLE) {
        if (_fleetOrderBookContract == address(0)) revert InvalidAddress();
        fleetOrderBookContract = IFleetOrderBook(_fleetOrderBookContract);
    }


    /// @notice Set the fleet operator book contract for the fleet order yield contract.
    /// @param _fleetOperatorBookContract The address of the fleet operator book contract.
    function setFleetOperatorBookContract(address _fleetOperatorBookContract) external onlyRole(SUPER_ADMIN_ROLE) {
        if (_fleetOperatorBookContract == address(0)) revert InvalidAddress();
        fleetOperatorBookContract = IFleetOperatorBook(_fleetOperatorBookContract);
    }


    /// @notice Set the fleet management service fee wallet for the fleet order yield contract.
    /// @param _fleetManagementServiceFeeWallet The address of the fleet management service fee wallet.
    function setFleetManagementServiceFeeWallet(address _fleetManagementServiceFeeWallet) external onlyRole(SUPER_ADMIN_ROLE) {
       if (_fleetManagementServiceFeeWallet == address(0)) revert InvalidAddress();
        fleetManagementServiceFeeWallet = _fleetManagementServiceFeeWallet;
    }


    /// @notice Set the fleet vehicle identification number.
    /// @param _fleetVehicleIdentificationNumber The vehicle identification number to set.
    function setFleetVehicleIdentificationNumberPerOrder(string memory _fleetVehicleIdentificationNumber, uint256 id) internal {
        fleetVehicleIdentificationNumberPerOrder[id] = _fleetVehicleIdentificationNumber;
    }


    /// @notice Set the fleet license plate number.
    /// @param _fleetLicensePlateNumber The license plate number to set.
    function setFleetLicensePlateNumberPerOrder(string memory _fleetLicensePlateNumber, uint256 id) internal {
        fleetLicensePlateNumberPerOrder[id] = _fleetLicensePlateNumber;
    }


    /// @notice Pay fee in ERC20.
    /// @param amount The amount of the ERC20 to pay in USD with 6 decimals.
    function payERC20(uint256 amount) internal {
        //IERC20 tokenContract = IERC20(erc20Contract);
        uint256 decimals = IERC20Metadata(address(yieldToken)).decimals();
        
        if (yieldToken.balanceOf(msg.sender) < ((amount * (10 ** decimals)) / 1e6)) revert NotEnoughTokens();
        yieldToken.safeTransferFrom(msg.sender, address(this), ((amount * (10 ** decimals)) / 1e6));
    }


    /// @notice Distribute the fleet owners yield to the fleet owners
    /// @param amount The amount of yield to share among the fleet owners
    /// @param id The id of the fleet order
    /// @return fleetOwners The addresses of the fleet owners
    function distributeFleetOwnersYield(uint256 amount, uint256 id) internal returns (address[] memory) {
        address[] memory fleetOwners = fleetOrderBookContract.getFleetOwners(id);
        uint256 decimals = IERC20Metadata(address(yieldToken)).decimals();
        uint256 amountPerFraction = ((amount * (10 ** decimals)) / 1e6) / fleetOrderBookContract.MAX_FLEET_FRACTION();
        for (uint256 i = 0; i < fleetOwners.length; i++) {
            uint256 shares = fleetOrderBookContract.totalSupply(id);
            uint256 amountPerOwner = shares * amountPerFraction;
            yieldToken.safeTransfer(fleetOwners[i], amountPerOwner);
            emit FleetOwnerSharesDividend(id, fleetOwners[i], amountPerOwner);
        }
        return fleetOwners;
    }


    /// @notice Pay the fleet weekly installment for a given id
    /// @param id The id of the fleet order
    /// @param payer The address of the driver the installment is made on behalf of
    function payFleetWeeklyInstallment(uint256 id, address payer) external nonReentrant {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        if (fleetOrderStatus[id] != ASSIGNED) revert OperatorNotAssigned();
        if ( fleetPaymentsDistributed[id] >= fleetOrderBookContract.getFleetLockPeriodPerOrder(id)) revert PaidFullAmount();
        // pay erc20 from drivers
        uint256 installmentAmount = fleetOrderBookContract.getFleetProtocolExpectedValuePerOrder(id) / fleetOrderBookContract.getFleetLockPeriodPerOrder(id);
        payERC20( installmentAmount );
        fleetPaymentsDistributed[id]++;

        emit FleetWeeklyInstallmentPaid(payer, id, fleetPaymentsDistributed[id], installmentAmount);


        // pay fleet owners
        uint256 fleetOwnersAmount = fleetOrderBookContract.getFleetLiquidityProviderExpectedValuePerOrder(id) / fleetOrderBookContract.getFleetLockPeriodPerOrder(id);
        address[] memory fleetOwners = distributeFleetOwnersYield( fleetOwnersAmount, id);

        emit FleetOwnersYieldDistributed(fleetPaymentsDistributed[id], id, fleetOwners, installmentAmount);
    }


    /// @notice Get the total payments distributed to a fleet order
    /// @param id The id of the fleet order
    /// @return uint256 The total payments distributed to the fleet order
    function getFleetPaymentsDistributed(uint256 id) external view returns (uint256) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        return fleetPaymentsDistributed[id];
    }


    /// @notice Check if a fleet order is operated by an address.
    /// @param operator The address of the operator.
    /// @param id The id of the fleet order to check.
    /// @return bool True if the fleet order is operated by the address, false otherwise.
    function isAddressFleetOperator(address operator, uint256 id) internal view returns (bool) {
        // If no orders exist for receiver, return false immediately.
        if (fleetOperators[id].length == 0) return false;
        
        // Retrieve the stored index for the order id.
        uint256 index = fleetOperatorsIndex[id][operator];

        // If the index is out of range, then id is not owned.
        if (index >= fleetOperators[id].length) return false;
        
        // Check that the order at that index matches the given id.
        return fleetOperators[id][index] == operator;
    }


    /// @notice Add a fleet order to the owner.
    /// @param operator The address of the operator.
    /// @param id The id of the fleet order to add.
    function addFleetOperated(address operator, uint256 id) internal {
        uint256[] storage owned = fleetOperated[operator];
        owned.push(id);
        fleetOperatedIndex[operator][id] = owned.length - 1;
    }


    /// @notice Add a fleet operator.
    /// @param operator The address of the operator.
    /// @param id The id of the fleet order to add.
    function addFleetOperator(address operator, uint256 id) internal {
        address[] storage operators = fleetOperators[id];
        operators.push(operator);
        fleetOperatorsIndex[id][operator] = operators.length - 1;
    }


    /// @notice Get the vehicle identification number of a fleet order.
    /// @param id The id of the fleet order.
    /// @return The vehicle identification number of the fleet order.
    function getFleetVehicleIdentificationNumberPerOrder(uint256 id) external view returns (string memory) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        return fleetVehicleIdentificationNumberPerOrder[id];
    }


    /// @notice Get the license plate number of a fleet order.
    /// @param id The id of the fleet order.
    /// @return The license plate number of the fleet order.
    function getFleetLicensePlateNumberPerOrder(uint256 id) external view returns (string memory) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        return fleetLicensePlateNumberPerOrder[id];
    }


    /// @notice Get the fleet orders operated by an address.
    /// @param operator The address of the operator.
    /// @return The fleet orders operated by the address.
    function getFleetOperated(address operator) external view returns (uint256[] memory) {
        return fleetOperated[operator];
    }


    /// @notice Get the fleet orders operated by an address.
    /// @param id The id of the fleet order.
    /// @return The operator of the fleet order.
    function getFleetOperators(uint256 id) external view returns (address[] memory) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        return fleetOperators[id];
    }


    /// @notice Check if a status value is valid
    /// @param status The status to check
    /// @return bool True if the status is valid
    function isValidStatus(uint256 status) internal pure returns (bool) {
        // Use bitwise operations for faster validation
        return status > 0 && status <= TRANSFERRED && (status & (status - 1)) == 0;
    }


    /// @notice Check if a state transition is valid
    /// @param currentStatus The current status
    /// @param newStatus The new status to transition to
    /// @return bool True if the transition is valid
    function isValidTransition(uint256 currentStatus, uint256 newStatus, uint256 id) internal view returns (bool) {
        if (currentStatus == SHIPPED) return newStatus == ARRIVED;
        if (currentStatus == ARRIVED) return newStatus == CLEARED;
        if (currentStatus == CLEARED) return false;
        if (currentStatus == REGISTERED) return false;
        if (currentStatus == ASSIGNED && fleetPaymentsDistributed[id] >= fleetOrderBookContract.getFleetLockPeriodPerOrder(id)) return newStatus == TRANSFERRED;
        return false;
    }



    /// @notice Check for duplicate IDs in an array
    /// @param ids The array of IDs to check
    /// @return bool True if there are no duplicates
    function hasNoDuplicates(uint256[] memory ids) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                if (ids[i] == ids[j]) return false;
            }
        }
        return true;
    }


    /// @notice Validate all status transitions in bulk
    /// @param ids The array of IDs to validate
    /// @param status The new status to validate against
    /// @return bool True if all transitions are valid
    function validateBulkTransitions(uint256[] memory ids, uint256 status) internal view returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == 0) return false;
            if (id > fleetOrderBookContract.totalFleet()) return false;
            
            uint256 currentStatus = fleetOrderStatus[id];
            if (currentStatus != 0 && !isValidTransition(currentStatus, status, id)) {
                return false;
            }
        }
        return true;
    }


    /// @notice Set the status of a fleet order
    /// @param id The id of the fleet order to set the status for
    /// @param status The new status to set
    function setFleetOrderStatus(uint256 id, uint256 status) internal {
        fleetOrderStatus[id] = status;
        emit FleetOrderStatusChanged(id, status);
    }


    /// @notice Generate the fleet order IDs for a container
    /// @param container The container to generate the fleet order IDs for
    /// @return The fleet order IDs for the container
    function generateContainerFleetOrderIDs(uint256 container) internal view returns (uint256[] memory) {
        uint256 fleetPerContainer = fleetOrderBookContract.getTotalFleetPerContainer(container);
        uint256 fleerPerLastContainer = fleetOrderBookContract.getTotalFleetPerContainer(container - 1);
        uint256 length = fleetPerContainer - fleerPerLastContainer;
        uint256[] memory ids = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            ids[i] = fleerPerLastContainer + i;
        }
        return ids;
    }


    /// @notice Set the status of multiple fleet orders
    /// @param container The container to set the status for
    /// @param status The new status to set
    function setBulkFleetOrderStatus(uint256 container, uint256 status) external onlyRole(SUPER_ADMIN_ROLE) {

        uint256[] memory ids = generateContainerFleetOrderIDs(container);
        // Early checks (cheap)
        if (ids.length == 0) revert InvalidAmount();
        if (ids.length > fleetOrderBookContract.getTotalFleetPerContainer(container)) revert BulkUpdateLimitExceeded();
        if (!hasNoDuplicates(ids)) revert DuplicateIds();
        if (!isValidStatus(status)) revert InvalidStatus();
        
        // Validate all transitions before making any changes
        if (!validateBulkTransitions(ids, status)) revert InvalidStateTransition();

        // Now we can safely update all statuses
        for (uint256 i = 0; i < ids.length; i++) {
            setFleetOrderStatus(ids[i], status);
        }
    }


    /// @notice Set tracking per container.
    /// @param _trackingPerContainer The tracking per container to set.
    function setTrackingPerContainer(string memory _trackingPerContainer, uint256 id) internal {
        trackingPerContainer[id] = _trackingPerContainer;
    }


    /// @notice Ship bulk fleet orders in a container with tracking.
    /// @param vins The VINs to create the fleet orders for.
    /// @param tracking The tracking to ship the fleet orders for.
    function shipContainerWithTracking(string[] memory vins, string memory tracking) external onlyRole(SUPER_ADMIN_ROLE) {
        if (fleetOrderBookContract.totalFleetOrderPerContainer() < fleetOrderBookContract.maxFleetOrderPerContainer()) revert MaxFleetOrderPerContainerNotReached();
        if (fleetOrderBookContract.totalSupply(fleetOrderBookContract.lastFleetFractionID()) < fleetOrderBookContract.MAX_FLEET_FRACTION()) revert MaxFleetOrderPerContainerNotReached();
        fleetOrderBookContract.startNextContainer();

        uint256[] memory ids = generateContainerFleetOrderIDs(fleetOrderBookContract.totalFleetContainerOrder());
        if (vins.length != ids.length) revert InvalidAmount();
        for (uint256 i = 0; i < ids.length; i++) {
            setFleetVehicleIdentificationNumberPerOrder(vins[i], ids[i]);
            setFleetOrderStatus(ids[i], SHIPPED);
        }
        setTrackingPerContainer(tracking, fleetOrderBookContract.totalFleetContainerOrder());
    }


    /// @notice Register a fleet order with a license plate number.
    /// @param id The id of the fleet order to register.
    /// @param licensePlateNumber The license plate number to register the fleet order with.
    function registerFleetOrderLicensePlateNumber(uint256 id, string memory licensePlateNumber) external onlyRole(SUPER_ADMIN_ROLE) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        if (fleetOrderStatus[id] != CLEARED) revert InvalidStatus();
        setFleetLicensePlateNumberPerOrder(licensePlateNumber, id);
    }

    /// @notice Check if a fleet operator is available to be assigned a new fleet.
    /// @param operator The address of the operator to check.
    /// @return bool True if the operator is available to be assigned a new fleet.
    function isFleetOperatorAvailable(address operator) external view returns (bool) {
        // operator can only be assigned a new fleet if not assigned any 
        // ...or most recent fleet is paid in full
        return fleetOperated[operator].length == 0 || fleetPaymentsDistributed[fleetOperated[operator][fleetOperated[operator].length - 1]] >= fleetOrderBookContract.getFleetLockPeriodPerOrder(fleetOperated[operator][fleetOperated[operator].length - 1]);
    }


    /// @notice Assign a fleet operator to a fleet order.
    /// @param id The id of the fleet order.
    function assignFleetOperator(uint256 id) external onlyRole(SUPER_ADMIN_ROLE) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        if (fleetOrderStatus[id] != REGISTERED) revert InvalidStatus();
        address operator = fleetOperatorBookContract.assignNextFleetOperatorReservation();
        addFleetOperator(operator, id);
        addFleetOperated(operator, id);
        setFleetOrderStatus(id, ASSIGNED);
        emit FleetOperatorAssigned(operator, id);
    }



    /// @notice Get the current status of a fleet order
    /// @param id The id of the fleet order to get the status for
    /// @return string The human-readable status string
    function getFleetOrderStatusReadable(uint256 id) public view returns (string memory) {
        if (id == 0) revert InvalidId();
        if (id > fleetOrderBookContract.totalFleet()) revert IdDoesNotExist();
        uint256 status = fleetOrderStatus[id];
        
        if (status == 0) return "Initialized";
        if (status == SHIPPED) return "Shipped";
        if (status == ARRIVED) return "Arrived";
        if (status == CLEARED) return "Cleared";
        if (status == REGISTERED) return "Registered";
        if (status == ASSIGNED) return "Assigned";
        if (status == TRANSFERRED) return "Transferred";
        
        revert InvalidStatus();
    }


    /// @notice Withdraw sales from fleet order book.
    /// @param token The address of the ERC20 contract.
    /// @param to The address to send the sales to.
    function withdrawFleetManagementServiceFee(address token, address to) external nonReentrant onlyRole(WITHDRAWAL_ROLE){
        if (token == address(0)) revert InvalidAddress();
        IERC20 tokenContract = IERC20(token);
        uint256 amount = tokenContract.balanceOf(address(this));
        if (amount == 0) revert NotEnoughTokens();
        tokenContract.safeTransfer(to, amount);
        emit FleetManagementServiceFeeWithdrawn(token, to, amount);
    }
    
    // =================================================== ADMIN MANAGEMENT ====================================================

    /// @notice Grant compliance role to an address
    /// @param account The address to grant the compliance role to
    function grantComplianceRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(COMPLIANCE_ROLE, account);
    }

    /// @notice Revoke compliance role from an address
    /// @param account The address to revoke the compliance role from
    function revokeComplianceRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(COMPLIANCE_ROLE, account);
    }

    /// @notice Grant withdrawal role to an address
    /// @param account The address to grant the withdrawal role to
    function grantWithdrawalRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(WITHDRAWAL_ROLE, account);
    }

    /// @notice Revoke withdrawal role from an address
    /// @param account The address to revoke the withdrawal role from
    function revokeWithdrawalRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(WITHDRAWAL_ROLE, account);
    }

    /// @notice Grant super admin role to an address
    /// @param account The address to grant the super admin role to
    function grantSuperAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(SUPER_ADMIN_ROLE, account);
    }

    /// @notice Revoke super admin role from an address
    /// @param account The address to revoke the super admin role from
    function revokeSuperAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(SUPER_ADMIN_ROLE, account);
    }

    /// @notice Check if an address has compliance role
    /// @param account The address to check
    /// @return bool True if the address has compliance role
    function isCompliance(address account) external view returns (bool) {
        return hasRole(COMPLIANCE_ROLE, account);
    }

    /// @notice Check if an address has withdrawal role
    /// @param account The address to check
    /// @return bool True if the address has withdrawal role
    function isWithdrawal(address account) external view returns (bool) {
        return hasRole(WITHDRAWAL_ROLE, account);
    }

    /// @notice Check if an address has super admin role
    /// @param account The address to check
    /// @return bool True if the address has super admin role
    function isSuperAdmin(address account) external view returns (bool) {
        return hasRole(SUPER_ADMIN_ROLE, account);
    }



}
