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
