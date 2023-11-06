use starknet::ContractAddress;
use serde::Serde;
use starknet::info::get_block_number;
use starknet::info::get_caller_address;
use starknet::info::get_contract_address;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;
use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcher;
use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcherTrait;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Withdraw {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedWithdraw {
    withdraw: Withdraw,
    sign: (felt252, felt252),
}

impl ZeroableImpl of Zeroable<Withdraw> {
    fn is_zero(self: Withdraw) -> bool {
        self == self.zero()
    }
    fn zero(self: Withdraw) -> Withdraw {
        let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        Withdraw { maker: zero_address, token: zero_address, amount: zero_u256, salt: 0 }
    }
}

use kurosawa_akira::utils::common::ChainCtx;
#[starknet::interface]
trait IWithdrawContract<TContractState> {
    fn request_onchain_withdraw(ref self: TContractState, withdraw: Withdraw, ctx: ChainCtx);
    fn make_onchain_withdraw(ref self: TContractState, withdraw: Withdraw, ctx: ChainCtx);
    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw);
}

#[starknet::contract]
mod WithdrawContract {
    use kurosawa_akira::utils::common::ChainCtx;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
    use starknet::ContractAddress;
    use super::Withdraw;
    use super::SignedWithdraw;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcher;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcherTrait;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;

    #[storage]
    struct Storage {
        slow_mode_contract: ContractAddress,
        exchange_balance_contract: ContractAddress,
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
    fn request_onchain_withdraw(ref self: ContractState, withdraw: Withdraw, ctx: ChainCtx) {
        let key = withdraw.get_poseidon_hash();
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_request_and_apply(withdraw.maker, key, ctx);
        self
            .emit(
                Event::request_onchain_withdraw(request_onchain_withdraw_s { withdraw: withdraw })
            );
    }

    #[external(v0)]
    fn make_onchain_withdraw(ref self: ContractState, withdraw: Withdraw, ctx: ChainCtx) {
        let key = withdraw.get_poseidon_hash();
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_delay(key, ctx);
        slow_mode_dispatcher.assert_have_request_and_apply(withdraw.maker, key, ctx);

        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        exchange_balance_dispatcher.burn(withdraw.maker, withdraw.amount, withdraw.token);
        IERC20Dispatcher { contract_address: withdraw.token }
            .transfer(withdraw.maker, withdraw.amount);
        self.emit(Event::make_onchain_withdraw(make_onchain_withdraw_s { withdraw: withdraw }));
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw) {
        let hash = signed_withdraw.withdraw.get_poseidon_hash();
        check_sign(signed_withdraw.withdraw.maker, hash, signed_withdraw.sign);
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        exchange_balance_dispatcher
            .burn(
                signed_withdraw.withdraw.maker,
                signed_withdraw.withdraw.amount,
                signed_withdraw.withdraw.token
            );
        IERC20Dispatcher { contract_address: signed_withdraw.withdraw.token }
            .transfer(signed_withdraw.withdraw.maker, signed_withdraw.withdraw.amount);
        self.emit(Event::apply_withdraw(apply_withdraw_s { withdraw: signed_withdraw.withdraw }));
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        request_onchain_withdraw: request_onchain_withdraw_s,
        make_onchain_withdraw: make_onchain_withdraw_s,
        apply_withdraw: apply_withdraw_s,
    }

    #[derive(Drop, starknet::Event)]
    struct request_onchain_withdraw_s {
        withdraw: Withdraw
    }

    #[derive(Drop, starknet::Event)]
    struct make_onchain_withdraw_s {
        withdraw: Withdraw
    }

    #[derive(Drop, starknet::Event)]
    struct apply_withdraw_s {
        withdraw: Withdraw
    }
}
