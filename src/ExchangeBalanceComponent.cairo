use starknet::ContractAddress;
use kurosawa_akira::Order::{GasFee,get_gas_fee_and_coin};



#[starknet::interface]
trait INewExchangeBalance<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;

    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;

    fn balancesOf(
        self: @TContractState, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>
    ) -> Array<Array<u256>>;

    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;

    fn get_latest_gas_price(self: @TContractState)->u256;

    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

    fn set_fee_recipient(ref self: TContractState,recipient:ContractAddress);
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
        fn set_fee_recipient(ref self: ComponentState<TContractState>,recipient:ContractAddress) {
            self.fee_recipient.write(recipient);
        }
    }
    #[generate_trait]
    impl InternalExchangeBalancebleImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalExchangeBalanceble<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>,fee_recipient:ContractAddress, wrapped_native_token:ContractAddress,latest_gas:u256) {
            self.wrapped_native_token.write(wrapped_native_token);
            self.fee_recipient.write(fee_recipient);
            self.latest_gas.write(latest_gas);
        }

        fn mint(
            ref self: ComponentState<TContractState>,
            to: ContractAddress,
            amount: u256,
            token: ContractAddress
        ) {
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
            gas_fee: super::GasFee,
            gas_price: u256
        ) {
            if gas_price == 0 || gas_fee.gas_per_action == 0 {
                return;
            }
            let (spent, coin) = super::get_gas_fee_and_coin(gas_fee, gas_price,self.wrapped_native_token.read());
            self.internal_transfer(user, self.fee_recipient.read(), spent, coin);
        }
    }
}
