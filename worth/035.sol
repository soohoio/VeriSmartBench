pragma solidity ^0.4.24;

contract Token {
    function transfer(address _to, uint _value) public returns (bool success);
    function transferFrom(address _from, address _to, uint _value) public returns (bool success);
    function approve(address _spender, uint _value) public returns (bool success);
}

/// @title localethereum.com
/// @author localethereum.com
contract LocalEthereumEscrows {
    /***********************
    +   Global settings   +
    ***********************/

    // Address of the arbitrator (currently always localethereum staff)
    address public arbitrator;
    // Address of the owner (who can withdraw collected fees)
    address public owner;
    // Address of the relayer (who is allowed to forward signed instructions from parties)
    address public relayer;
    uint32 public requestCancellationMinimumTime;
    // Cumulative balance of collected fees
    uint256 public feesAvailableForWithdraw;

    /***********************
    +  Instruction types  +
    ***********************/

    // Called when the buyer marks payment as sent. Locks funds in escrow
    uint8 constant INSTRUCTION_SELLER_CANNOT_CANCEL = 0x01;
    // Buyer cancelling
    uint8 constant INSTRUCTION_BUYER_CANCEL = 0x02;
    // Seller cancelling
    uint8 constant INSTRUCTION_SELLER_CANCEL = 0x03;
    // Seller requesting to cancel. Begins a window for buyer to object
    uint8 constant INSTRUCTION_SELLER_REQUEST_CANCEL = 0x04;
    // Seller releasing funds to the buyer
    uint8 constant INSTRUCTION_RELEASE = 0x05;
    // Either party permitting the arbitrator to resolve a dispute
    uint8 constant INSTRUCTION_RESOLVE = 0x06;

    /***********************
    +       Events        +
    ***********************/

    event Created(bytes32 indexed _tradeHash);
    event SellerCancelDisabled(bytes32 indexed _tradeHash);
    event SellerRequestedCancel(bytes32 indexed _tradeHash);
    event CancelledBySeller(bytes32 indexed _tradeHash);
    event CancelledByBuyer(bytes32 indexed _tradeHash);
    event Released(bytes32 indexed _tradeHash);
    event DisputeResolved(bytes32 indexed _tradeHash);

    struct Escrow {
        // So we know the escrow exists
        bool exists;
        // This is the timestamp in whic hthe seller can cancel the escrow after.
        // It has two special values:
        // 0 : Permanently locked by the buyer (i.e. marked as paid; the seller can never cancel)
        // 1 : The seller can only request to cancel, which will change this value to a timestamp.
        //     This option is avaialble for complex trade terms such as cash-in-person where a
        //     payment window is inappropriate
        uint32 sellerCanCancelAfter;
        // Cumulative cost of gas incurred by the relayer. This amount will be refunded to the owner
        // in the way of fees once the escrow has completed
        uint128 totalGasFeesSpentByRelayer;
    }

    // Mapping of active trades. The key here is a hash of the trade proprties
    mapping (bytes32 => Escrow) public escrows;

    modifier onlyOwner() {
        require(msg.sender == owner, "Must be owner");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Must be arbitrator");
        _;
    }

    /// @notice Initialize the contract.
    constructor() public {
        owner = msg.sender;
        arbitrator = msg.sender;
        relayer = msg.sender;
        requestCancellationMinimumTime = 2 hours;
    }

    /// @notice Create and fund a new escrow.
    /// @param _tradeID The unique ID of the trade, generated by localethereum.com
    /// @param _seller The selling party
    /// @param _buyer The buying party
    /// @param _value The amount of the escrow, exclusive of the fee
    /// @param _fee Localethereum's commission in 1/10000ths
    /// @param _paymentWindowInSeconds The time in seconds from escrow creation that the seller can cancel after
    /// @param _expiry This transaction must be created before this time
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    function createEscrow(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint32 _paymentWindowInSeconds,
        uint32 _expiry,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) payable external {
        // The trade hash is created by tightly-concatenating and hashing properties of the trade.
        // This hash becomes the identifier of the escrow, and hence all these variables must be
        // supplied on future contract calls
        bytes32 _tradeHash = keccak256(abi.encodePacked(_tradeID, _seller, _buyer, _value, _fee));
        // Require that trade does not already exist
        require(!escrows[_tradeHash].exists, "Trade already exists");
        // A signature (v, r and s) must come from localethereum to open an escrow
        bytes32 _invitationHash = keccak256(abi.encodePacked(
            _tradeHash,
            _paymentWindowInSeconds,
            _expiry
        ));
        require(recoverAddress(_invitationHash, _v, _r, _s) == relayer, "Must be relayer");
        // These signatures come with an expiry stamp
        require(block.timestamp < _expiry, "Signature has expired");
        // Check transaction value against signed _value and make sure is not 0
        require(msg.value == _value && msg.value > 0, "Incorrect ether sent");
        uint32 _sellerCanCancelAfter = _paymentWindowInSeconds == 0
            ? 1
            : uint32(block.timestamp) + _paymentWindowInSeconds;
        // Add the escrow to the public mapping
        escrows[_tradeHash] = Escrow(true, _sellerCanCancelAfter, 0);
        emit Created(_tradeHash);
    }

    uint16 constant GAS_doResolveDispute = 36100;
    /// @notice Called by the arbitrator to resolve a dispute. Requires a signature from either party.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    /// @param _buyerPercent What % should be distributed to the buyer (this is usually 0 or 100)
    function resolveDispute(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint8 _buyerPercent
    ) external onlyArbitrator {
        address _signature = recoverAddress(keccak256(abi.encodePacked(
            _tradeID,
            INSTRUCTION_RESOLVE
        )), _v, _r, _s);
        require(_signature == _buyer || _signature == _seller, "Must be buyer or seller");

        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        require(_escrow.exists, "Escrow does not exist");
        require(_buyerPercent <= 100, "_buyerPercent must be 100 or lower");

        uint256 _totalFees = _escrow.totalGasFeesSpentByRelayer + (GAS_doResolveDispute * uint128(tx.gasprice));
        require(_value - _totalFees <= _value, "Overflow error"); // Prevent underflow
        feesAvailableForWithdraw += _totalFees; // Add the the pot for localethereum to withdraw

        delete escrows[_tradeHash];
        emit DisputeResolved(_tradeHash);
        if (_buyerPercent > 0)
          _buyer.transfer((_value - _totalFees) * _buyerPercent / 100);
        if (_buyerPercent < 100)
          _seller.transfer((_value - _totalFees) * (100 - _buyerPercent) / 100);
    }

    /// @notice Release ether in escrow to the buyer. Direct call option.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return bool
    function release(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) external returns (bool){
        require(msg.sender == _seller, "Must be seller");
        return doRelease(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Disable the seller from cancelling (i.e. "mark as paid"). Direct call option.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return bool
    function disableSellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) external returns (bool) {
        require(msg.sender == _buyer, "Must be buyer");
        return doDisableSellerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Cancel the escrow as a buyer. Direct call option.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return bool
    function buyerCancel(
      bytes16 _tradeID,
      address _seller,
      address _buyer,
      uint256 _value,
      uint16 _fee
    ) external returns (bool) {
        require(msg.sender == _buyer, "Must be buyer");
        return doBuyerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Cancel the escrow as a seller. Direct call option.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return bool
    function sellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) external returns (bool) {
        require(msg.sender == _seller, "Must be seller");
        return doSellerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Request to cancel as a seller. Direct call option.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return bool
    function sellerRequestCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) external returns (bool) {
        require(msg.sender == _seller, "Must be seller");
        return doSellerRequestCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Relay multiple signed instructions from parties of escrows.
    /// @param _tradeID List of _tradeID values
    /// @param _seller List of _seller values
    /// @param _buyer List of _buyer values
    /// @param _value List of _value values
    /// @param _fee List of _fee values
    /// @param _maximumGasPrice List of _maximumGasPrice values
    /// @param _v List of signature "v" components
    /// @param _r List of signature "r" components
    /// @param _s List of signature "s" components
    /// @param _instructionByte List of _instructionByte values
    /// @return bool List of results
    uint16 constant GAS_batchRelayBaseCost = 28500;
    function batchRelay(
        bytes16[] _tradeID,
        address[] _seller,
        address[] _buyer,
        uint256[] _value,
        uint16[] _fee,
        uint128[] _maximumGasPrice,
        uint8[] _v,
        bytes32[] _r,
        bytes32[] _s,
        uint8[] _instructionByte
    ) public returns (bool[]) {
        bool[] memory _results = new bool[](_tradeID.length);
        uint128 _additionalGas = uint128(msg.sender == relayer ? GAS_batchRelayBaseCost / _tradeID.length : 0);
        for (uint8 i=0; i<_tradeID.length; i++) {
            _results[i] = relay(
                _tradeID[i],
                _seller[i],
                _buyer[i],
                _value[i],
                _fee[i],
                _maximumGasPrice[i],
                _v[i],
                _r[i],
                _s[i],
                _instructionByte[i],
                _additionalGas
            );
        }
        return _results;
    }

    /// @notice Withdraw fees collected by the contract. Only the owner can call this.
    /// @param _to Address to withdraw fees in to
    /// @param _amount Amount to withdraw
    function withdrawFees(address _to, uint256 _amount) onlyOwner external {
        // This check also prevents underflow
        require(_amount <= feesAvailableForWithdraw, "Amount is higher than amount available");
        feesAvailableForWithdraw -= _amount;
        _to.transfer(_amount);
    }

    /// @notice Set the arbitrator to a new address. Only the owner can call this.
    /// @param _newArbitrator Address of the replacement arbitrator
    function setArbitrator(address _newArbitrator) onlyOwner external {
        arbitrator = _newArbitrator;
    }

    /// @notice Change the owner to a new address. Only the owner can call this.
    /// @param _newOwner Address of the replacement owner
    function setOwner(address _newOwner) onlyOwner external {
        owner = _newOwner;
    }

    /// @notice Change the relayer to a new address. Only the owner can call this.
    /// @param _newRelayer Address of the replacement relayer
    function setRelayer(address _newRelayer) onlyOwner external {
        relayer = _newRelayer;
    }

    /// @notice Change the requestCancellationMinimumTime. Only the owner can call this.
    /// @param _newRequestCancellationMinimumTime Replacement
    function setRequestCancellationMinimumTime(
        uint32 _newRequestCancellationMinimumTime
    ) onlyOwner external {
        requestCancellationMinimumTime = _newRequestCancellationMinimumTime;
    }

    /// @notice Send ERC20 tokens away. This function allows the owner to withdraw stuck ERC20 tokens.
    /// @param _tokenContract Token contract
    /// @param _transferTo Recipient
    /// @param _value Value
    function transferToken(
        Token _tokenContract,
        address _transferTo,
        uint256 _value
    ) onlyOwner external {
        _tokenContract.transfer(_transferTo, _value);
    }

    /// @notice Send ERC20 tokens away. This function allows the owner to withdraw stuck ERC20 tokens.
    /// @param _tokenContract Token contract
    /// @param _transferTo Recipient
    /// @param _transferFrom Sender
    /// @param _value Value
    function transferTokenFrom(
        Token _tokenContract,
        address _transferTo,
        address _transferFrom,
        uint256 _value
    ) onlyOwner external {
        _tokenContract.transferFrom(_transferTo, _transferFrom, _value);
    }

    /// @notice Send ERC20 tokens away. This function allows the owner to withdraw stuck ERC20 tokens.
    /// @param _tokenContract Token contract
    /// @param _spender Spender address
    /// @param _value Value
    function approveToken(
        Token _tokenContract,
        address _spender,
        uint256 _value
    ) onlyOwner external {
        _tokenContract.approve(_spender, _value);
    }

    /// @notice Relay a signed instruction from a party of an escrow.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _maximumGasPrice Maximum gas price permitted for the relayer (set by the instructor)
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function relay(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _maximumGasPrice,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint8 _instructionByte,
        uint128 _additionalGas
    ) private returns (bool) {
        address _relayedSender = getRelayedSender(
            _tradeID,
            _instructionByte,
            _maximumGasPrice,
            _v,
            _r,
            _s
        );
        if (_relayedSender == _buyer) {
            // Buyer's instructions:
            if (_instructionByte == INSTRUCTION_SELLER_CANNOT_CANCEL) {
                // Disable seller from cancelling
                return doDisableSellerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_BUYER_CANCEL) {
                // Cancel
                return doBuyerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            }
        } else if (_relayedSender == _seller) {
            // Seller's instructions:
            if (_instructionByte == INSTRUCTION_RELEASE) {
                // Release
                return doRelease(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_SELLER_CANCEL) {
                // Cancel
                return doSellerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_SELLER_REQUEST_CANCEL){
                // Request to cancel
                return doSellerRequestCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            }
        } else {
            require(msg.sender == _seller, "Unrecognised party");
            return false;
        }
    }

    /// @notice Increase the amount of gas to be charged later on completion of an escrow
    /// @param _tradeHash Trade hash
    /// @param _gas Gas cost
    function increaseGasSpent(bytes32 _tradeHash, uint128 _gas) private {
        escrows[_tradeHash].totalGasFeesSpentByRelayer += _gas * uint128(tx.gasprice);
    }

    /// @notice Transfer the value of an escrow, minus the fees, minus the gas costs incurred by relay
    /// @param _to Recipient address
    /// @param _value Value of the transfer
    /// @param _totalGasFeesSpentByRelayer Total gas fees spent by the relayer
    /// @param _fee Commission in 1/10000ths
    function transferMinusFees(
        address _to,
        uint256 _value,
        uint128 _totalGasFeesSpentByRelayer,
        uint16 _fee
    ) private {
        uint256 _totalFees = (_value * _fee / 10000) + _totalGasFeesSpentByRelayer;
        // Prevent underflow
        if(_value - _totalFees > _value) {
            return;
        }
        // Add fees to the pot for localethereum to withdraw
        feesAvailableForWithdraw += _totalFees;
        _to.transfer(_value - _totalFees);
    }

    uint16 constant GAS_doRelease = 46588;
    /// @notice Release escrow to the buyer. This completes it and removes it from the mapping.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function doRelease(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (msg.sender == relayer
                ? (GAS_doRelease + _additionalGas ) * uint128(tx.gasprice)
                : 0
            );
        delete escrows[_tradeHash];
        emit Released(_tradeHash);
        transferMinusFees(_buyer, _value, _gasFees, _fee);
        return true;
    }

    uint16 constant GAS_doDisableSellerCancel = 28944;
    /// @notice Prevents the seller from cancelling an escrow. Used to "mark as paid" by the buyer.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function doDisableSellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        if(_escrow.sellerCanCancelAfter == 0) return false;
        escrows[_tradeHash].sellerCanCancelAfter = 0;
        emit SellerCancelDisabled(_tradeHash);
        if (msg.sender == relayer) {
          increaseGasSpent(_tradeHash, GAS_doDisableSellerCancel + _additionalGas);
        }
        return true;
    }

    uint16 constant GAS_doBuyerCancel = 46255;
    /// @notice Cancels the trade and returns the ether to the seller. Can only be called the buyer.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function doBuyerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) {
            return false;
        }
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (msg.sender == relayer
                ? (GAS_doBuyerCancel + _additionalGas ) * uint128(tx.gasprice)
                : 0
            );
        delete escrows[_tradeHash];
        emit CancelledByBuyer(_tradeHash);
        transferMinusFees(_seller, _value, _gasFees, 0);
        return true;
    }

    uint16 constant GAS_doSellerCancel = 46815;
    /// @notice Returns the ether in escrow to the seller. Called by the seller. Sometimes unavailable.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function doSellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) {
            return false;
        }
        if(_escrow.sellerCanCancelAfter <= 1 || _escrow.sellerCanCancelAfter > block.timestamp) {
            return false;
        }
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (msg.sender == relayer
                ? (GAS_doSellerCancel + _additionalGas ) * uint128(tx.gasprice)
                : 0
            );
        delete escrows[_tradeHash];
        emit CancelledBySeller(_tradeHash);
        transferMinusFees(_seller, _value, _gasFees, 0);
        return true;
    }

    uint16 constant GAS_doSellerRequestCancel = 29507;
    /// @notice Request to cancel. Used if the buyer is unresponsive. Begins a countdown timer.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @param _additionalGas Additional gas to be deducted after this operation
    /// @return bool
    function doSellerRequestCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        // Called on unlimited payment window trades where the buyer is not responding
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) {
            return false;
        }
        if(_escrow.sellerCanCancelAfter != 1) {
            return false;
        }
        escrows[_tradeHash].sellerCanCancelAfter = uint32(block.timestamp)
            + requestCancellationMinimumTime;
        emit SellerRequestedCancel(_tradeHash);
        if (msg.sender == relayer) {
          increaseGasSpent(_tradeHash, GAS_doSellerRequestCancel + _additionalGas);
        }
        return true;
    }

    /// @notice Get the sender of the signed instruction.
    /// @param _tradeID Identifier of the trade
    /// @param _instructionByte Identifier of the instruction
    /// @param _maximumGasPrice Maximum gas price permitted by the sender
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    /// @return address
    function getRelayedSender(
      bytes16 _tradeID,
      uint8 _instructionByte,
      uint128 _maximumGasPrice,
      uint8 _v,
      bytes32 _r,
      bytes32 _s
    ) view private returns (address) {
        bytes32 _hash = keccak256(abi.encodePacked(
            _tradeID,
            _instructionByte,
            _maximumGasPrice
        ));
        if(tx.gasprice > _maximumGasPrice) {
            return;
        }
        return recoverAddress(_hash, _v, _r, _s);
    }

    /// @notice Hashes the values and returns the matching escrow object and trade hash.
    /// @dev Returns an empty escrow struct and 0 _tradeHash if not found.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee parameter
    /// @return Escrow
    function getEscrowAndHash(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) view private returns (Escrow, bytes32) {
        bytes32 _tradeHash = keccak256(abi.encodePacked(
            _tradeID,
            _seller,
            _buyer,
            _value,
            _fee
        ));
        return (escrows[_tradeHash], _tradeHash);
    }

    /// @notice Returns an empty escrow struct and 0 _tradeHash if not found.
    /// @param _h Data to be hashed
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    /// @return address
    function recoverAddress(
        bytes32 _h,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) private pure returns (address) {
        bytes memory _prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 _prefixedHash = keccak256(abi.encodePacked(_prefix, _h));
        return ecrecover(_prefixedHash, _v, _r, _s);
    }
}
