use starknet::ContractAddress;
use kurosawa_akira::FeeLogic::GasFee::GasFee;

#[starknet::interface]
trait IExchangeBalance<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;
    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;
    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256, token: ContractAddress);
    fn burn(ref self: TContractState, from: ContractAddress, amount: u256, token: ContractAddress);
    fn internal_transfer(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256,
        token: ContractAddress
    );
    fn validate_and_apply_gas_fee_internal(
        ref self: TContractState, user: ContractAddress, gas_fee: GasFee
    );
    fn get_gas_fee_and_coin(
        ref self: TContractState, gas_fee: GasFee, cur_gas_price: u256
    ) -> (u256, core::starknet::contract_address::ContractAddress);
    fn get_cur_gas_price(self: @TContractState) -> u256;
    fn set_cur_gas_price(ref self: TContractState, gas_price: u256);
    fn get_cur_value(self: @TContractState) -> u256;
    fn set_cur_value(ref self: TContractState, gas_price: u256);
}


#[starknet::contract]
mod ExchangeBalance {
    use starknet::ContractAddress;
    use kurosawa_akira::FeeLogic::GasFee::GasFee;

    #[storage]
    struct Storage {
        _total_supply: LegacyMap::<ContractAddress, u256>,
        _balance: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        wrapped_native_token: ContractAddress,
        exchange_address: ContractAddress,
        cur_gas_price: u256,
        cur_value: u256,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        wrapped_native_token: ContractAddress,
        exchange_address: ContractAddress
    ) {
        self.wrapped_native_token.write(wrapped_native_token);
        self.exchange_address.write(wrapped_native_token);
    }

    #[external(v0)]
    fn total_supply(self: @ContractState, token: ContractAddress) -> u256 {
        self._total_supply.read(token)
    }

    #[external(v0)]
    fn balanceOf(self: @ContractState, address: ContractAddress, token: ContractAddress) -> u256 {
        self._balance.read((token, address))
    }
    #[external(v0)]
    fn get_wrapped_native_token(self: @ContractState) -> ContractAddress {
        self.wrapped_native_token.read()
    }

    #[external(v0)]
    fn mint(ref self: ContractState, to: ContractAddress, amount: u256, token: ContractAddress) {
        self._total_supply.write(token, self._total_supply.read(token) + amount);
        self._balance.write((token, to), self._balance.read((token, to)) + amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, from: ContractAddress, amount: u256, token: ContractAddress) {
        self._total_supply.write(token, self._total_supply.read(token) - amount);
        self._balance.write((token, from), self._balance.read((token, from)) - amount);
    }

    #[external(v0)]
    fn internal_transfer(
        ref self: ContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256,
        token: ContractAddress
    ) {
        assert(self._balance.read((token, from)) >= amount, 'Few balance');
        self._balance.write((token, from), self._balance.read((token, from)) - amount);
        self._balance.write((token, to), self._balance.read((token, to)) + amount);
    }
    #[external(v0)]
    fn get_gas_fee_and_coin(
        ref self: ContractState, gas_fee: GasFee, cur_gas_price: u256
    ) -> (u256, core::starknet::contract_address::ContractAddress) {
        if cur_gas_price == 0 {
            return (0, self.wrapped_native_token.read());
        }
        if gas_fee.gas_per_swap == 0 {
            return (0, self.wrapped_native_token.read());
        }
        assert(gas_fee.max_gas_price >= cur_gas_price, 'gas_prc <-= user stated prc');

        let spend_native = gas_fee.gas_per_swap * cur_gas_price;
        if (gas_fee.fee_token == self.wrapped_native_token.read()) && !gas_fee.external_call {
            return (spend_native, self.wrapped_native_token.read());
        } else if gas_fee.fee_token == self.wrapped_native_token.read() && gas_fee.external_call {
            return (spend_native, self.wrapped_native_token.read());
        }

        let spend_converted = (spend_native * gas_fee.conversion_rate - 1) / 1000000000000000000
            + 1;
        return (spend_converted, gas_fee.fee_token);
    }


    #[external(v0)]
    fn validate_and_apply_gas_fee_internal(
        ref self: ContractState, user: ContractAddress, gas_fee: GasFee
    ) {
        if self.cur_gas_price.read() == 0 {
            return;
        }
        if gas_fee.gas_per_swap == 0 {
            return;
        }
        assert(gas_fee.max_gas_price >= self.cur_gas_price.read(), 'gas_prc <-= user stated prc');
        assert(gas_fee.external_call == false, 'unsafe external call');
        let (spend, coin) = get_gas_fee_and_coin(ref self, gas_fee, self.cur_gas_price.read());
        internal_transfer(ref self, user, self.exchange_address.read(), spend, gas_fee.fee_token);
        self
            .emit(
                Event::fee_event(
                    fee_event_s {
                        user: user,
                        _exchange_address: self.exchange_address.read(),
                        coin: coin,
                        spend: spend
                    }
                )
            );
    }

    #[external(v0)]
    fn get_cur_gas_price(self: @ContractState) -> u256 {
        self.cur_gas_price.read()
    }
    #[external(v0)]
    fn set_cur_gas_price(ref self: ContractState, gas_price: u256) {
        self.cur_gas_price.write(gas_price);
    }

    #[external(v0)]
    fn get_cur_value(self: @ContractState) -> u256 {
        self.cur_value.read()
    }
    #[external(v0)]
    fn set_cur_value(ref self: ContractState, gas_price: u256) {
        self.cur_value.write(gas_price);
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        fee_event: fee_event_s,
    }

    #[derive(Drop, starknet::Event)]
    struct fee_event_s {
        user: ContractAddress,
        _exchange_address: ContractAddress,
        coin: ContractAddress,
        spend: u256,
    }
}


#[starknet::interface]
trait INewExchangeBalance<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;

    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;

    fn balancesOf(
        self: @TContractState, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>
    ) -> Array<Array<u256>>;

    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;

    fn get_gas_fee_and_coin(
        self: @TContractState, gas_fee: NewGasFee, cur_gas_price: u256
    ) -> (u256, ContractAddress);

    fn get_latest_gas_price(self: @TContractState)->u256;

    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

}


// TODO use this once all stuff rewritten in components
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct NewGasFee {
    gas_per_action: u256,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: (u256, u256),
    external_call: bool,
}


#[starknet::component]
mod exchange_balance_logic_component {
    use starknet::{ContractAddress, get_caller_address};
    use super::INewExchangeBalance;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        GasFeeEvent: GasFeeEvent
    }

    #[derive(Drop, starknet::Event)]
    struct GasFeeEvent {
        #[key]
        user: ContractAddress,
        #[key]
        coin: ContractAddress,
        spent: u256
    }

    #[storage]
    struct Storage {
        _total_supply: LegacyMap::<ContractAddress, u256>,
        _balances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        wrapped_native_token: ContractAddress,
        exchange_address: ContractAddress,
        fee_recipient: ContractAddress,
        latest_gas: u256,
    }




    #[embeddable_as(ExchangeBalanceble)]
    impl ExchangeBalancebleImpl<TContractState, +HasComponent<TContractState>> of INewExchangeBalance<ComponentState<TContractState>> {
        // TODO add modifier that this is internal method ?
        

        fn total_supply(self: @ComponentState<TContractState>, token: ContractAddress) -> u256 {
            return self._total_supply.read(token);
        }

        fn balanceOf(
            self: @ComponentState<TContractState>, address: ContractAddress, token: ContractAddress
        ) -> u256 {
            return self._balances.read((token, address));
        }

        fn balancesOf(
            self: @ComponentState<TContractState>,
            addresses: Span<ContractAddress>,
            tokens: Span<ContractAddress>
        ) -> Array<Array<u256>> {
            let mut res: Array<Array<u256>> = ArrayTrait::new();
            let sz_addr = addresses.len();
            let sz_token = tokens.len();
            let mut idx_addr = 0;
            loop {
                let addr = *addresses.at(idx_addr);
                let mut sub_res: Array<u256> = ArrayTrait::new();
                let mut idx_token = 0;
                loop {
                    let token = *tokens.at(idx_token);
                    sub_res.append(self._balances.read((token, addr)));
                    idx_token += 1;
                    if sz_token == idx_token {
                        break;
                    }
                };
                res.append(sub_res);
                idx_addr += 1;
                if sz_addr == idx_addr {
                    break;
                }
            };
            return res;
        }

        fn get_wrapped_native_token(self: @ComponentState<TContractState>) -> ContractAddress {
            return self.wrapped_native_token.read();
        }

        fn get_fee_recipient(self: @ComponentState<TContractState>) -> ContractAddress {
            return self.fee_recipient.read();
        }
        fn get_latest_gas_price(self: @ComponentState<TContractState>) -> u256 {
            return self.latest_gas.read();
        }

        fn get_gas_fee_and_coin(
            self: @ComponentState<TContractState>, gas_fee: super::NewGasFee, cur_gas_price: u256
        ) -> (u256, core::starknet::contract_address::ContractAddress) {
            if cur_gas_price == 0 {
                return (0, self.wrapped_native_token.read());
            }
            if gas_fee.gas_per_action == 0 {
                return (0, self.wrapped_native_token.read());
            }
            assert(gas_fee.max_gas_price >= cur_gas_price, 'gas_prc <-= user stated prc');

            let spend_native = gas_fee.gas_per_action * cur_gas_price;
            if (gas_fee.fee_token == self.wrapped_native_token.read()) && !gas_fee.external_call {
                return (spend_native, self.wrapped_native_token.read());
            } else if gas_fee.fee_token == self.wrapped_native_token.read()
                && gas_fee.external_call {
                return (spend_native, self.wrapped_native_token.read());
            }
            let (r0, r1) = gas_fee.conversion_rate;
            let spend_converted = spend_native * r1 / r0;
            return (spend_converted, gas_fee.fee_token);
        }
    }
    #[generate_trait]
    impl InternalExchangeBalancebleImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalExchangeBalanceble<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>,fee_recipient:ContractAddress, wrapped_native_token:ContractAddress, exchange_address: ContractAddress) {
            self.exchange_address.write(exchange_address);
            self.wrapped_native_token.write(wrapped_native_token);
            self.fee_recipient.write(fee_recipient);
        }

        fn mint(
            ref self: ComponentState<TContractState>,
            to: ContractAddress,
            amount: u256,
            token: ContractAddress
        ) {
            assert(get_caller_address() == self.exchange_address.read(), 'Only self');
            self._total_supply.write(token, self._total_supply.read(token) + amount);
            self._balances.write((token, to), self._balances.read((token, to)) + amount);
        }

        fn burn(
            ref self: ComponentState<TContractState>,
            from: ContractAddress,
            amount: u256,
            token: ContractAddress
        ) {
            self._total_supply.write(token, self._total_supply.read(token) - amount);
            self._balances.write((token, from), self._balances.read((token, from)) - amount);
        }
        fn internal_transfer(
            ref self: ComponentState<TContractState>,
            from: ContractAddress,
            to: ContractAddress,
            amount: u256,
            token: ContractAddress
        ) {
            assert(self._balances.read((token, from)) >= amount, 'Few balance');
            self._balances.write((token, from), self._balances.read((token, from)) - amount);
            self._balances.write((token, to), self._balances.read((token, to)) + amount);
        }

        fn validate_and_apply_gas_fee_internal(
            ref self: ComponentState<TContractState>,
            user: ContractAddress,
            gas_fee: super::NewGasFee,
            gas_price: u256
        ) {
            if gas_price == 0 || gas_fee.gas_per_action == 0 {
                return;
            }
            assert(gas_fee.external_call == false, 'unsafe external call');
            let (spent, coin) = self.get_gas_fee_and_coin(gas_fee, gas_price);
            self.internal_transfer(user, self.fee_recipient.read(), spent, gas_fee.fee_token);
            self
                .emit(
                    GasFeeEvent { user: user, coin: coin, spent: spent }
                ); // TODO do we need event here? maybe just for debug?
        }
    }
}
