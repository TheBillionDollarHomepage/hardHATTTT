// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {ISuperfluid, ISuperToken, ISuperApp, ISuperAgreement, SuperAppDefinitions, ISuperfluidToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {CFAv1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/CFAv1Library.sol";

import {IConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import {SuperAppBase} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

import {BillionDollarCanvas} from "./BillionDollarCanvas.sol";

/// @dev Constant Flow Agreement registration key, used to get the address from the host.
bytes32 constant CFA_ID = keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");

/// @dev Thrown when the receiver is the zero adress.
error InvalidReceiver();

/// @dev Thrown when receiver is also a super app.
error ReceiverIsSuperApp();

/// @dev Thrown when the callback caller is not the host.
error Unauthorized();

/// @dev Thrown when the token being streamed to this contract is invalid
error InvalidToken();

/// @dev Thrown when the agreement is other than the Constant Flow Agreement V1
error InvalidAgreement();

/// @title Stream Redirection Contract
/// @notice This contract is a registered super app, meaning it receives
contract RedirectAll is SuperAppBase {
    // CFA library setup
    using CFAv1Library for CFAv1Library.InitData;
    CFAv1Library.InitData public cfaV1Lib;

    /// @dev Super token that may be streamed to this contract
    ISuperToken internal immutable _acceptedToken;

    /// @notice This is the current receiver that all streams will be redirected to.
    address public _receiver;

    BillionDollarCanvas billionDollarCanvas;

    constructor(
        ISuperfluid host,
        ISuperToken acceptedToken,
        address receiver,
        address canvasContract
    ) {
        assert(address(host) != address(0));
        assert(address(acceptedToken) != address(0));
        assert(receiver != address(0));

        _acceptedToken = acceptedToken;
        _receiver = receiver;
        billionDollarCanvas = BillionDollarCanvas(canvasContract);

        cfaV1Lib = CFAv1Library.InitData({
            host: host,
            cfa: IConstantFlowAgreementV1(address(host.getAgreementClass(CFA_ID)))
        });

        // Registers Super App, indicating it is the final level (it cannot stream to other super
        // apps), and that the `before*` callbacks should not be called on this contract, only the
        // `after*` callbacks.
        host.registerApp(
            SuperAppDefinitions.APP_LEVEL_FINAL |
                SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP
        );
    }

    // ---------------------------------------------------------------------------------------------
    // EVENTS

    /// @dev Logged when the receiver changes
    /// @param receiver The new receiver address.
    event ReceiverChanged(address indexed receiver);

    // ---------------------------------------------------------------------------------------------
    // MODIFIERS

    modifier onlyHost() {
        if (msg.sender != address(cfaV1Lib.host)) revert Unauthorized();
        _;
    }

    modifier onlyExpected(ISuperToken superToken, address agreementClass) {
        if (superToken != _acceptedToken) revert InvalidToken();
        if (agreementClass != address(cfaV1Lib.cfa)) revert InvalidAgreement();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // RECEIVER DATA

    /// @notice Returns current receiver's address, start time, and flow rate.
    /// @return startTime Start time of the current flow.
    /// @return receiver Receiving address.
    /// @return flowRate Flow rate from this contract to the receiver.
    function currentReceiver()
        external
        view
        returns (
            uint256 startTime,
            address receiver,
            int96 flowRate
        )
    {
        if (receiver != address(0)) {
            (startTime, flowRate, , ) = cfaV1Lib.cfa.getFlow(
                _acceptedToken,
                address(this),
                _receiver
            );

            receiver = _receiver;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // SUPER APP CALLBACKS

    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, //_agreementId
        bytes calldata _agreementData,
        bytes calldata, //_cbdata
        bytes calldata _ctx
    )
        external
        override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        // decode data from context
        (address sender, address receiver) = abi.decode(
            _agreementData,
            (address, address)
        );
        ISuperfluid.Context memory context = ISuperfluid(msg.sender).decodeCtx(_ctx);
        (uint256 canvasId, string memory uri, uint256 price) = abi.decode(
            context.userData,
            (uint256, string, uint256)
        );

        // logic for buying canvas
        (, int96 outFlowRate, , ) = cfaV1Lib.cfa.getFlow(_acceptedToken, sender, receiver);
        require(outFlowRate >= billionDollarCanvas.getFeePerSecond(canvasId));

        address moneyReceiver;

        try billionDollarCanvas.ownerOfCanvas(canvasId) {
            moneyReceiver = billionDollarCanvas.ownerOf(canvasId);
        } catch {
            moneyReceiver = billionDollarCanvas.getGitCoinAddress();
        }

        _acceptedToken.transferFrom(context.msgSender, moneyReceiver, price);

        billionDollarCanvas.buyFor(context.msgSender, canvasId, uri, price);

        return _updateOutflow(_ctx);
    }

    function afterAgreementUpdated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData,
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    )
        external
        override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        // decode data from context
        ISuperfluid.Context memory context = ISuperfluid(msg.sender).decodeCtx(_ctx);
        (uint256 canvasId, uint256 price) = abi.decode(
            context.userData,
            (uint256, uint256)
        );

        // logic for updating stream -> chaning price
        (, int96 outFlowRate, , ) = cfaV1Lib.cfa.getFlow(_acceptedToken, sender, receiver);
        require(outFlowRate >= billionDollarCanvas.getFeePerSecond(canvasId));

        billionDollarCanvas.setPrice(canvasId, price);

        return _updateOutflow(_ctx);
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        // According to the app basic law, we should never revert in a termination callback
        if (_superToken != _acceptedToken || _agreementClass != address(cfaV1Lib.cfa)) {
            return _ctx;
        }

        // decode data from context
        ISuperfluid.Context memory context = ISuperfluid(msg.sender).decodeCtx(_ctx);
        (address sender, uint256 canvasId) = abi.decode(
            context.userData,
            (address, uint256)
        );

        // when stream is termimated reset canvas and give it free for initial selling
        billionDollarCanvas.resetCanvas(canvasId, 0);

        return _updateOutflow(_ctx);
    }

    // ---------------------------------------------------------------------------------------------
    // INTERNAL LOGIC

    /// @dev Changes receiver and redirects all flows to the new one. Logs `ReceiverChanged`.
    /// @param newReceiver The new receiver to redirect to.
    function _changeReceiver(address newReceiver) internal {
        if (newReceiver == address(0)) revert InvalidReceiver();
getFlow
        if (cfaV1Lib.host.isApp(ISuperApp(newReceiver))) revert ReceiverIsSuperApp();

        if (newReceiver == _receiver) return;

        (, int96 outFlowRate, , ) = cfaV1Lib.cfa.getFlow(_acceptedToken, address(this), _receiver);

        if (outFlowRate > 0) {
            cfaV1Lib.deleteFlow(address(this), _receiver, _acceptedToken);

            cfaV1Lib.createFlow(
                newReceiver,
                _acceptedToken,
                cfaV1Lib.cfa.getNetFlow(_acceptedToken, address(this))
            );
        }

        _receiver = newReceiver;

        emit ReceiverChanged(newReceiver);
    }

    /// @dev Updates the outflow. The flow is either created, updated, or deleted, depending on the
    /// net flow rate.
    /// @param ctx The context byte array from the Host's calldata.
    /// @return newCtx The new context byte array to be returned to the Host.
    function _updateOutflow(bytes calldata ctx) private returns (bytes memory newCtx) {
        newCtx = ctx;

        int96 netFlowRate = cfaV1Lib.cfa.getNetFlow(_acceptedToken, address(this));

        (, int96 outFlowRate, , ) = cfaV1Lib.cfa.getFlow(_acceptedToken, address(this), _receiver);

        int96 inFlowRate = netFlowRate + outFlowRate;

        if (inFlowRate == 0) {
            // The flow does exist and should be deleted.
            newCtx = cfaV1Lib.deleteFlowWithCtx(ctx, address(this), _receiver, _acceptedToken);
        } else if (outFlowRate != 0) {
            // The flow does exist and needs to be updated.
            newCtx = cfaV1Lib.updateFlowWithCtx(ctx, _receiver, _acceptedToken, inFlowRate);
        } else {
            // The flow does not exist but should be created.
            newCtx = cfaV1Lib.createFlowWithCtx(ctx, _receiver, _acceptedToken, inFlowRate);
        }
    }
}
