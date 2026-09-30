// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BatchCofheClient} from "../helpers/BatchCofheClient.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockGmxReader} from "../helpers/GmxMocks.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Milestone 3: sealed intake on CoFHE mocks.
contract SealedOrderAdapterIntakeTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);

    uint256 private constant COLLATERAL = 1 ether;
    uint256 private constant EXEC_FEE = 0.001 ether;

    function setUp() public {
        MockGmxDataStore dataStore = new MockGmxDataStore();
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(new MockGmxExchangeRouter()),
                router: address(0x0B7),
                orderVault: address(0x0FA),
                dataStore: address(dataStore),
                roleStore: address(new MockGmxRoleStore()),
                wnt: WNT
            }),
            makeAddr("feeCollector")
        );
        _deployAdapter(address(impl), WNT, MARKET, address(new MockGmxReader()), address(dataStore));
        _fund(alice.account(), 5 ether);
        _fund(bob.account(), 5 ether);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _input(BatchCofheClient client, Plain memory p)
        internal
        returns (SealedOrderAdapter.SealedOrderInput memory)
    {
        return _input(client, MARKET, COLLATERAL, EXEC_FEE, p);
    }
    function _valid() internal pure returns (Plain memory) {
        return Plain({isLong: true, size: 5_000e6, trigger: 2_400e8, slippage: 50});
    }

    function _submit(BatchCofheClient client, Plain memory p) internal returns (bytes32 orderId) {
        SealedOrderAdapter.SealedOrderInput memory input = _input(client, p);
        vm.prank(client.account());
        orderId = adapter.submitOrder(input);
    }

    function _intakeValid(bytes32 orderId) internal view returns (bool) {
        return getPlaintext(adapter.orderOf(orderId).intakeValid);
    }

    // ─── intake ───────────────────────────────────────────────────────────────

    function test_submit_storesSealedFieldsAndPublicTerms() public {
        Plain memory p = _valid();
        bytes32 orderId = _submit(alice, p);

        SealedOrderAdapter.SealedOrder memory o = adapter.orderOf(orderId);
        assertEq(o.owner, alice.account());
        assertEq(o.account, adapter.accountOf(alice.account()));
        assertEq(o.market, MARKET);
        assertEq(uint8(o.status), uint8(SealedOrderAdapter.Status.Open));
        assertEq(o.collateral, COLLATERAL);
        expectPlaintext(o.isLong, p.isLong);
        expectPlaintext(o.sizeUsd6, p.size);
        expectPlaintext(o.triggerPrice8, p.trigger);
        expectPlaintext(o.slippageBps, p.slippage);
        expectPlaintext(o.intakeValid, true);
    }

    function test_submit_createsAccountOnFirstUseAndLocksFunds() public {
        address account = adapter.accountOf(alice.account());
        assertEq(account.code.length, 0, "account not deployed before first order");

        bytes32 orderId = _submit(alice, _valid());

        assertGt(account.code.length, 0, "account deployed");
        IUserAccount.Lock memory l = IUserAccount(account).lockOf(orderId);
        assertEq(l.collateral, COLLATERAL);
        assertEq(l.feePerAttempt, EXEC_FEE);
        assertEq(l.attemptsLeft, 2);
        assertEq(l.protocolFeeReserve, COLLATERAL * MAX_LEVERAGE * FEE_BPS / 10_000, "reserve from max order");
        assertEq(
            IUserAccount(account).freeBalance(WNT),
            5 ether - COLLATERAL - 2 * EXEC_FEE - l.protocolFeeReserve
        );
    }

    function test_submit_ownerCanAccessOwnSealedFields_strangerCannot() public {
        bytes32 orderId = _submit(alice, _valid());
        SealedOrderAdapter.SealedOrder memory o = adapter.orderOf(orderId);
        bytes32[5] memory handles = [
            ebool.unwrap(o.isLong),
            euint64.unwrap(o.sizeUsd6),
            euint64.unwrap(o.triggerPrice8),
            euint32.unwrap(o.slippageBps),
            ebool.unwrap(o.intakeValid)
        ];
        for (uint256 i; i < handles.length; i++) {
            assertTrue(mockAcl.isAllowed(uint256(handles[i]), alice.account()), "owner allowed");
            assertTrue(mockAcl.isAllowed(uint256(handles[i]), address(adapter)), "adapter allowed");
            assertFalse(mockAcl.isAllowed(uint256(handles[i]), bob.account()), "other user not allowed");
            assertFalse(mockAcl.globalAllowed(uint256(handles[i])), "not public before fire");
        }
    }

    // ─── replay (design §6) ───────────────────────────────────────────────────

    function test_replay_otherUserCannotSubmitAlicesEncryptedInputs() public {
        SealedOrderAdapter.SealedOrderInput memory stolen = _input(alice, _valid());

        vm.prank(bob.account());
        vm.expectPartialRevert(bytes4(keccak256("InvalidSigner(address,address)")));
        adapter.submitOrder(stolen);
    }

    function test_replay_inputsBoundToAnotherContractAreRejected() public {
        SealedOrderAdapter.SealedOrderInput memory input = _input(alice, _valid());
        (input.isLong, input.sizeUsd6, input.triggerPrice8, input.slippageBps, input.inputProof) =
            alice.encryptOrder(true, 5_000e6, 2_400e8, 50, address(0xBEEF));

        vm.prank(alice.account());
        vm.expectPartialRevert(bytes4(keccak256("InvalidSigner(address,address)")));
        adapter.submitOrder(input);
    }

    // ─── encrypted caps: failures don't revert and aren't visible ─────────────

    function test_caps_sizeBelowMinimum_marksInvalid() public {
        Plain memory p = _valid();
        p.size = MIN_SIZE - 1;
        assertFalse(_intakeValid(_submit(alice, p)));
    }

    function test_caps_sizeAboveMaximum_marksInvalid() public {
        Plain memory p = _valid();
        p.size = MAX_SIZE + 1;
        assertFalse(_intakeValid(_submit(alice, p)));
    }

    function test_caps_slippageAboveMaximum_marksInvalid() public {
        Plain memory p = _valid();
        p.slippage = MAX_SLIPPAGE + 1;
        assertFalse(_intakeValid(_submit(alice, p)));
    }

    function test_caps_zeroTrigger_marksInvalid() public {
        Plain memory p = _valid();
        p.trigger = 0;
        assertFalse(_intakeValid(_submit(alice, p)));
    }

    function test_caps_boundariesAreInclusive() public {
        Plain memory p = _valid();
        p.size = MIN_SIZE;
        p.slippage = MAX_SLIPPAGE;
        assertTrue(_intakeValid(_submit(alice, p)));
        p.size = MAX_SIZE;
        assertTrue(_intakeValid(_submit(alice, p)));
    }

    function test_caps_invalidOrderStillLocksFunds_soItLooksLikeAnyOther() public {
        Plain memory p = _valid();
        p.size = MAX_SIZE + 1;
        bytes32 orderId = _submit(alice, p);
        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Open));
        assertEq(IUserAccount(adapter.accountOf(alice.account())).lockOf(orderId).collateral, COLLATERAL);
    }

    // ─── plaintext validation ─────────────────────────────────────────────────

    function test_submit_rejectsUnsupportedMarket() public {
        SealedOrderAdapter.SealedOrderInput memory input = _input(alice, _valid());
        input.market = address(0xBAD);
        vm.prank(alice.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.UnsupportedMarket.selector, address(0xBAD)));
        adapter.submitOrder(input);
    }

    function test_submit_rejectsLowExecutionFee() public {
        SealedOrderAdapter.SealedOrderInput memory input = _input(alice, _valid());
        input.executionFee = MIN_EXEC_FEE - 1;
        vm.prank(alice.account());
        vm.expectRevert(
            abi.encodeWithSelector(SealedOrderAdapter.ExecutionFeeTooLow.selector, MIN_EXEC_FEE - 1, MIN_EXEC_FEE)
        );
        adapter.submitOrder(input);
    }

    function test_submit_rejectsHighFallbackSlippage() public {
        SealedOrderAdapter.SealedOrderInput memory input = _input(alice, _valid());
        input.fallbackSlippageBps = MAX_FALLBACK_SLIPPAGE + 1;
        vm.prank(alice.account());
        vm.expectRevert(
            abi.encodeWithSelector(
                SealedOrderAdapter.FallbackSlippageTooHigh.selector, MAX_FALLBACK_SLIPPAGE + 1, MAX_FALLBACK_SLIPPAGE
            )
        );
        adapter.submitOrder(input);
    }

    function test_submit_rejectsUnderfundedAccount() public {
        SealedOrderAdapter.SealedOrderInput memory input = _input(alice, _valid());
        input.collateral = 10 ether;
        vm.prank(alice.account());
        vm.expectPartialRevert(IUserAccount.InsufficientFreeBalance.selector);
        adapter.submitOrder(input);
    }

    // ─── cancel ───────────────────────────────────────────────────────────────

    function test_cancel_releasesLockAndClosesOrder() public {
        bytes32 orderId = _submit(alice, _valid());
        address account = adapter.accountOf(alice.account());

        vm.prank(alice.account());
        adapter.cancelOrder(orderId);

        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Cancelled));
        assertEq(IUserAccount(account).freeBalance(WNT), 5 ether, "everything withdrawable again");
    }

    function test_cancel_onlyOwner_andOnlyOnce() public {
        bytes32 orderId = _submit(alice, _valid());

        vm.prank(bob.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotOrderOwner.selector, orderId));
        adapter.cancelOrder(orderId);

        vm.startPrank(alice.account());
        adapter.cancelOrder(orderId);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.OrderNotOpen.selector, orderId));
        adapter.cancelOrder(orderId);
        vm.stopPrank();
    }

    function test_ordersFromDifferentUsersUseSeparateAccounts() public {
        bytes32 a = _submit(alice, _valid());
        bytes32 b = _submit(bob, _valid());
        assertTrue(adapter.orderOf(a).account != adapter.orderOf(b).account);
    }
}
