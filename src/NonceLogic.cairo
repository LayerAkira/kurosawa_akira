use kurosawa_akira::FeeLogic::GasFee::GasFee;
use starknet::ContractAddress;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct IncreaseNonce {
    maker: ContractAddress,
    new_nonce: u256,
    gas_fee: GasFee,
    salt: felt252,
}
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedIncreaseNonce {
    increase_nonce: IncreaseNonce,
    sign: (felt252, felt252),
}


#[starknet::interface]
trait INonceLogic<TContractState> {
    fn apply_increase_nonce(ref self: TContractState, signed_nonce_increase: SignedIncreaseNonce);
    fn get_nonce(self: @TContractState, maker: ContractAddress) -> u256;
}


#[starknet::contract]
mod NonceLogic {
    use starknet::ContractAddress;
    use super::IncreaseNonce;
    use super::SignedIncreaseNonce;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;

    #[storage]
    struct Storage {
        exchange_balance_contract: ContractAddress,
        nonces: LegacyMap::<ContractAddress, u256>,
    }


    #[constructor]
    fn constructor(ref self: ContractState, exchange_balance_contract: ContractAddress) {
        self.exchange_balance_contract.write(exchange_balance_contract);
    }

    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce_increase: SignedIncreaseNonce) {
        let nonce_increase = signed_nonce_increase.increase_nonce;
        let key = nonce_increase.get_poseidon_hash();
        check_sign(nonce_increase.maker, key, signed_nonce_increase.sign);
        assert(nonce_increase.new_nonce > self.nonces.read(nonce_increase.maker), 'Wrong nonce');
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        exchange_balance_dispatcher
            .validate_and_apply_gas_fee_internal(nonce_increase.maker, nonce_increase.gas_fee);
        self.nonces.write(nonce_increase.maker, nonce_increase.new_nonce);

        self.emit(Event::nonce_increase(nonce_increase_s { nonce_increase: nonce_increase }));
    }


    #[external(v0)]
    fn get_nonce(self: @ContractState, maker: ContractAddress) -> u256 {
        self.nonces.read(maker)
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        nonce_increase: nonce_increase_s,
    }

    #[derive(Drop, starknet::Event)]
    struct nonce_increase_s {
        nonce_increase: IncreaseNonce,
    }
}
