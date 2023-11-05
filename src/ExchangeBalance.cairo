
use starknet::ContractAddress;
#[starknet::interface]
trait ISlowMode<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;
    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;
    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256, token: ContractAddress);
    fn burn(ref self: TContractState, from: ContractAddress, amount: u256, token: ContractAddress);
    fn internal_transfer(ref self: TContractState, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress);
}


#[starknet::contract]
mod ExchangeBalanceContract{
    use starknet::ContractAddress;

    #[storage]
    struct Storage {
        _total_supply: LegacyMap::<ContractAddress, u256>,
        _balance: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        wrapped_native_token: ContractAddress,
        exchange_address: ContractAddress,
    }


    #[constructor]
    fn constructor(ref self: ContractState, wrapped_native_token: ContractAddress, exchange_address: ContractAddress) {
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
    fn get_wrapped_native_token(self: @ContractState) -> ContractAddress{
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
    fn internal_transfer(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress){
        assert(self._balance.read((token, from)) >= amount, 'Few balance');
        self._balance.write((token, from), self._balance.read((token, from)) - amount);
        self._balance.write((token, to), self._balance.read((token, to)) + amount);
    }



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}



}