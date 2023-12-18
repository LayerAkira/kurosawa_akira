use starknet::ContractAddress;

#[starknet::interface]
trait IDeposit<TContractState> {
    fn deposit(ref self: TContractState, receiver:ContractAddress, token:ContractAddress, amount:u256);
}

#[starknet::component]
mod deposit_component {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use starknet::{get_caller_address,get_contract_address,ContractAddress};

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        receiver: ContractAddress,
        token: ContractAddress,
        funder:ContractAddress,
        amount: u256
    }


    #[storage]
    struct Storage {}

    #[embeddable_as(Depositable)]
    impl DepositableImpl<TContractState, +HasComponent<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>> of super::IDeposit<ComponentState<TContractState>> {

        fn deposit(ref self: ComponentState<TContractState>, receiver:ContractAddress, token:ContractAddress, amount:u256) {
            let caller = get_caller_address();
            let contract = get_contract_address();
            let mut b_contract = self.get_balancer_mut();
            let erc20 = IERC20Dispatcher { contract_address: token };

            let pre = erc20.balanceOf(contract);
            erc20.transferFrom(caller, contract, amount);
            let fact_received = erc20.balanceOf(contract) - pre;
            assert(fact_received == amount, 'WRONG_AMOUNT');

            b_contract.mint(receiver, amount, token);
            self.emit(Deposit{receiver:receiver, token:token, funder:caller, amount:amount});
        }

    }



    // this (or something similar) will potentially be generated in the next RC
    #[generate_trait]
    impl GetBalancer<
        TContractState,
        +HasComponent<TContractState>,
        +balance_component::HasComponent<TContractState>,
        +Drop<TContractState>> of GetBalancerTrait<TContractState> {
        fn get_balancer(
            self: @ComponentState<TContractState>
        ) -> @balance_component::ComponentState<TContractState> {
            let contract = self.get_contract();
            balance_component::HasComponent::<TContractState>::get_component(contract)
        }

        fn get_balancer_mut(
            ref self: ComponentState<TContractState>
        ) -> balance_component::ComponentState<TContractState> {
            let mut contract = self.get_contract_mut();
            balance_component::HasComponent::<TContractState>::get_component_mut(ref contract)
        }
    }
}
