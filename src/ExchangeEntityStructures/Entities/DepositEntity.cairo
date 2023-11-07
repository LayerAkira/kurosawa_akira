use starknet::ContractAddress;
use starknet::info::get_block_number;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::ExchangeEntity::Applying;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Pending;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use starknet::info::get_caller_address;
use starknet::info::get_contract_address;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHash;
use starknet::Event;
use traits::Into;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Deposit {
    maker: ContractAddress,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct DepositApply {
    key: felt252,
    sign: (felt252, felt252),
}

impl ZeroableImpl of Zeroable<Deposit> {
    fn is_zero(self: Deposit) -> bool {
        self == self.zero()
    }
    fn zero(self: Deposit) -> Deposit {
        let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        Deposit {
            maker: zero_address,
            receiver: zero_address,
            token: zero_address,
            amount: zero_u256,
            salt: 0
        }
    }
}

#[starknet::interface]
trait IDepositContract<TContractState> {
    fn set_pending(ref self: TContractState, deposit: Deposit) -> felt252;
    fn request_cancellation_pending(ref self: TContractState, key: felt252);
    fn cancel_pending(ref self: TContractState, key: felt252);
    fn apply_pending_deposit(ref self: TContractState, deposit_apply: DepositApply);
}


#[starknet::contract]
mod DepositContract {
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
    use starknet::ContractAddress;
    use super::Deposit;
    use super::DepositApply;
    use super::ZeroableImpl;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcher;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcherTrait;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
    use starknet::info::get_block_number;
    use starknet::info::get_caller_address;
    use starknet::info::get_contract_address;

    #[storage]
    struct Storage {
        slow_mode_contract: ContractAddress,
        exchange_balance_contract: ContractAddress,
        _pending_deposits: LegacyMap::<felt252, Deposit>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        slow_mode_contract: ContractAddress,
        exchange_balance_contract: ContractAddress
    ) {
        self.slow_mode_contract.write(slow_mode_contract);
        self.exchange_balance_contract.write(exchange_balance_contract)
    }

    #[external(v0)]
    fn set_pending(ref self: ContractState, deposit: Deposit) -> felt252 {
        let caller = get_caller_address();
        let contract = get_contract_address();
        assert(caller == deposit.maker, 'only deposits by user himself');
        assert(contract == deposit.receiver, 'only deposits to exchange');
        //TODO
        // assert(deposit.value == ctx.value && self.deposit_price == ctx.value, 'wrong value')

        let key = deposit.get_poseidon_hash();
        assert(self._pending_deposits.read(key).is_zero(), 'Deposit already pending');

        let pre = IERC20Dispatcher { contract_address: deposit.token }.balanceOf(contract);
        IERC20Dispatcher { contract_address: deposit.token }
            .transferFrom(deposit.maker, contract, deposit.amount);
        let fact_received = IERC20Dispatcher { contract_address: deposit.token }.balanceOf(contract)
            - pre;
        assert(fact_received == deposit.amount, 'Wrong received amount');

        //TODO
        // FakeERC20(self._wrapped_base_token).transfer(deposit.receiver, deposit.value.value, ctx)
        self._pending_deposits.write(key, deposit);
        key
    }

    #[external(v0)]
    fn request_cancellation_pending(ref self: ContractState, key: felt252) {
        let deposit = self._pending_deposits.read(key);
        assert(!deposit.is_zero(), 'not_pending');
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_request_and_apply(deposit.maker, key);
        self
            .emit(
                Event::request_cancellation_pending(
                    request_cancellation_pending_s { deposit: deposit }
                )
            );
    }

    #[external(v0)]
    fn cancel_pending(ref self: ContractState, key: felt252) {
        let deposit = self._pending_deposits.read(key);
        assert(!deposit.is_zero(), 'not_pending');
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_delay(key);
        slow_mode_dispatcher.assert_have_request_and_apply(deposit.maker, key);
        self._pending_deposits.write(key, deposit.zero());

        IERC20Dispatcher { contract_address: deposit.token }
            .transfer(deposit.maker, deposit.amount);
        self.emit(Event::cancel_pending(cancel_pending_s { deposit: deposit }));
    }

    #[external(v0)]
    fn apply_pending_deposit(ref self: ContractState, deposit_apply: DepositApply) {
        let deposit = self._pending_deposits.read(deposit_apply.key);
        check_sign(deposit.maker, deposit_apply.key, deposit_apply.sign);
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        exchange_balance_dispatcher.mint(deposit.maker, deposit.amount, deposit.token);
        self._pending_deposits.write(deposit_apply.key, deposit.zero());
        self.emit(Event::apply_pending_deposit(apply_pending_deposit_s { deposit: deposit }));
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        request_cancellation_pending: request_cancellation_pending_s,
        cancel_pending: cancel_pending_s,
        apply_pending_deposit: apply_pending_deposit_s,
    }

    #[derive(Drop, starknet::Event)]
    struct request_cancellation_pending_s {
        deposit: Deposit
    }

    #[derive(Drop, starknet::Event)]
    struct cancel_pending_s {
        deposit: Deposit
    }

    #[derive(Drop, starknet::Event)]
    struct apply_pending_deposit_s {
        deposit: Deposit
    }
}
