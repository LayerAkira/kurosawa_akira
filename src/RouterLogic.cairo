use starknet::ContractAddress;

#[starknet::interface]
trait IRouterLogicContract<TContractState> {
    #[external(v0)]
    fn is_registered(self: @TContractState, router: ContractAddress);

    #[external(v0)]
    fn update_router_stake_amount(ref self: TContractState, new: u256);

    #[external(v0)]
    fn blocklist(ref self: TContractState, router: ContractAddress);

    #[external(v0)]
    fn router_deposit(ref self: TContractState, router: ContractAddress);
    fn router_withdraw(
        ref self: TContractState, router: ContractAddress, coin: ContractAddress, amount: u256,
    );
    fn register_router(
        ref self: TContractState,
        router: ContractAddress,
        whitelisted_signers: Array::<ContractAddress>,
    );
    fn unregister_start(ref self: TContractState, router: ContractAddress);
    fn unregister_finish(ref self: TContractState, router: ContractAddress);
    fn unregister_cancel(ref self: TContractState, router: ContractAddress);

    fn remove_binding(ref self: TContractState, router: ContractAddress, signer: ContractAddress);
    fn add_binding(ref self: TContractState, router: ContractAddress, signer: ContractAddress);
    fn validate_router(
        self: @TContractState,
        message: felt252,
        signature: (felt252, felt252),
        router: ContractAddress
    );
    fn get_punishment_factor_bips(self: @TContractState) -> u256;
}

#[starknet::contract]
mod RouterLogicContract {
    use starknet::ContractAddress;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcher;
    use kurosawa_akira::utils::SlowModeLogic::ISlowModeDispatcherTrait;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        slow_mode_contract: ContractAddress,
        exchange_balance_contract: ContractAddress,
        akira_contract: ContractAddress,
        exchange_contract: ContractAddress,
        blocklisted: LegacyMap::<ContractAddress, bool>,
        signer_to_router: LegacyMap::<ContractAddress, ContractAddress>,
        router_stake_amount: u256,
        enable_trading_min: u256,
        wrapped_native_token: ContractAddress,
        punishment_factor_bips: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        slow_mode_contract: ContractAddress,
        exchange_balance_contract: ContractAddress,
        exchange_contract: ContractAddress,
        akira_contract: ContractAddress,
        router_stake_amount: u256,
        enable_trading_min: u256,
        wrapped_native_token: ContractAddress,
        punishment_factor_bips: u256
    ) {
        self.slow_mode_contract.write(slow_mode_contract);
        self.exchange_balance_contract.write(exchange_balance_contract);
        self.exchange_contract.write(exchange_contract);
        self.akira_contract.write(akira_contract);
        assert(enable_trading_min <= router_stake_amount, 'wrong trading_min');
        self.router_stake_amount.write(router_stake_amount);
        self.enable_trading_min.write(enable_trading_min);
        self.wrapped_native_token.write(wrapped_native_token);
        self.punishment_factor_bips.write(punishment_factor_bips);
    }
    #[external(v0)]
    fn is_registered(self: @ContractState, router: ContractAddress) -> bool {
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        return exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read()) > 0;
    }

    #[external(v0)]
    fn update_router_stake_amount(ref self: ContractState, new: u256) {
        // let akira_contract_dispatcher = ISlowModeDispatcher {
        //     contract_address: self.slow_mode_contract.read()
        // };
        // assert(ctx.caller == self._akira._exchange_invoker, 'Wrong caller')
        assert(self.enable_trading_min.read() <= new, 'less than min');
        self.router_stake_amount.write(new);
    }

    #[external(v0)]
    fn blocklist(ref self: ContractState, router: ContractAddress) {
        // assert ctx.caller == self._akira._exchange_invoker, 'Wrong caller'
        assert(is_registered(@self, router), 'Router not registered');
        self.blocklisted.write(router, true);

        self.emit(Event::router_blocklist_event(router_blocklist_event_s { router: router }));
    }

    #[external(v0)]
    fn router_deposit(ref self: ContractState, router: ContractAddress) {

            let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };

        IERC20Dispatcher { contract_address: self.wrapped_native_token.read() }
            .transfer(self.exchange_contract.read(), exchange_balance_dispatcher.get_cur_value());



        let b_old = exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read());
        exchange_balance_dispatcher.mint(router, exchange_balance_dispatcher.get_cur_value(), self.wrapped_native_token.read());

        let b = exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read());

        self
            .emit(
                Event::binding_balance_event(
                    binding_balance_event_s {
                        router: router,
                        token: self.wrapped_native_token.read(),
                        old_balance: b_old,
                        balance: b,
                    }
                )
            );
    }

    #[external(v0)]
    fn router_withdraw(
        ref self: ContractState, router: ContractAddress, coin: ContractAddress, amount: u256,
    ) {
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        let caller = get_caller_address();
        assert(caller == router, 'Wrong caller');
        assert(
            exchange_balance_dispatcher.balanceOf(router, coin) >= amount, 'Insufficient tokens'
        );
        if is_registered(@self, router) {
            assert(
                exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read())
                    - amount >= self.enable_trading_min.read(),
                'Should be left min'
            );
        }

        let b_old = exchange_balance_dispatcher.balanceOf(router, coin);

        exchange_balance_dispatcher.burn(router, amount, coin);

        // ctx.caller = self.exchange_contract.read();

        IERC20Dispatcher { contract_address: coin }.transfer(router, amount);

        let b = exchange_balance_dispatcher.balanceOf(router, coin);

        self
            .emit(
                Event::binding_balance_event(
                    binding_balance_event_s {
                        router: router,
                        token: self.wrapped_native_token.read(),
                        old_balance: b_old,
                        balance: b,
                    }
                )
            );
    }

    #[external(v0)]
    fn register_router(
        ref self: ContractState,
        router: ContractAddress,
        whitelisted_signers: Array::<ContractAddress>,
    ) {
        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        assert(exchange_balance_dispatcher.get_cur_value() >= self.router_stake_amount.read(), 'Must place stake amount');
        assert(
            exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read()) > 0,
            'Already registered'
        );
        let mut current_index = 0;
        let last_ind = whitelisted_signers.len();
        loop {
            if (current_index == last_ind) {
                break true;
            }
            let signer = *whitelisted_signers[current_index];
            assert(self.signer_to_router.read(signer).is_zero(), 'Signer already used');
            self.signer_to_router.write(signer, router);
            current_index += 1;
        };
        IERC20Dispatcher { contract_address: self.wrapped_native_token.read() }
            .transfer(self.exchange_contract.read(), exchange_balance_dispatcher.get_cur_value());

        let old_b = exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read());
        exchange_balance_dispatcher.mint(router, exchange_balance_dispatcher.get_cur_value(), self.wrapped_native_token.read());

        let b = exchange_balance_dispatcher.balanceOf(router, self.wrapped_native_token.read());

        self
            .emit(
                Event::router_registered_event(
                    router_registered_event_s {
                        router: router,
                        old_balance: old_b,
                        balance: b, // whitelisted_signers: whitelisted_signers,
                        registered: true,
                    }
                )
            );
    }

    #[external(v0)]
    fn unregister_start(ref self: ContractState, router: ContractAddress) {
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_request_and_apply(router, router.get_poseidon_hash());
        self
            .emit(
                Event::pending_unregister(
                    pending_unregister_s { router: router, registered: false, }
                )
            );
    }

    #[external(v0)]
    fn unregister_finish(ref self: ContractState, router: ContractAddress) {
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };

        slow_mode_dispatcher.assert_delay(router.get_poseidon_hash());
        slow_mode_dispatcher.assert_have_request_and_apply(router, router.get_poseidon_hash());

        let exchange_balance_dispatcher = IExchangeBalanceDispatcher {
            contract_address: self.exchange_balance_contract.read()
        };
        let balance = exchange_balance_dispatcher
            .balanceOf(router, self.wrapped_native_token.read());
        exchange_balance_dispatcher.burn(router, balance, self.wrapped_native_token.read());

        IERC20Dispatcher { contract_address: self.wrapped_native_token.read() }
            .transfer(self.exchange_contract.read(), balance);

        self
            .emit(
                Event::router_registered_event(
                    router_registered_event_s {
                        router: router,
                        old_balance: balance,
                        balance: 0, // whitelisted_signers: whitelisted_signers,
                        registered: true,
                    }
                )
            );
    }
    #[external(v0)]
    fn unregister_cancel(ref self: ContractState, router: ContractAddress) {
        let slow_mode_dispatcher = ISlowModeDispatcher {
            contract_address: self.slow_mode_contract.read()
        };
        slow_mode_dispatcher.assert_have_request_and_apply(router, router.get_poseidon_hash());
        self
            .emit(
                Event::pending_unregister(
                    pending_unregister_s { router: router, registered: false, }
                )
            );
    }
    #[external(v0)]
    fn remove_binding(ref self: ContractState, router: ContractAddress, signer: ContractAddress) {
        let caller = get_caller_address();
        assert(router == caller, 'Wrong caller');
        assert(is_registered(@self, router) == false, 'Only when not registered router');
        assert(!self.signer_to_router.read(signer).is_zero(), 'No binding');
        assert(self.signer_to_router.read(signer) == router, 'Wrong binding');
        //  TODO check this semantic
        self
            .signer_to_router
            .write(signer, starknet::contract_address_try_from_felt252(0).unwrap());

        self
            .emit(
                Event::binding_change_event(
                    binding_change_event_s { router: router, signer: signer, is_add: false, }
                )
            );
    }
    #[external(v0)]
    fn add_binding(ref self: ContractState, router: ContractAddress, signer: ContractAddress) {
        let caller = get_caller_address();
        assert(router == caller, 'Wrong caller');
        assert(is_registered(@self, router), 'Not registered router');
        assert(self.signer_to_router.read(signer).is_zero(), 'Already binding');
        self.signer_to_router.write(signer, router);

        self
            .emit(
                Event::binding_change_event(
                    binding_change_event_s { router: router, signer: signer, is_add: true, }
                )
            );
    }
    #[external(v0)]
    fn validate_router(
        self: @ContractState,
        message: felt252,
        signature: (felt252, felt252),
        router: ContractAddress
    ) {
        // recovered_signer = None
        // assert(recovered_signer in self.signer_to_router, 'No binding'
        // assert(self.signer_to_router[recovered_signer] == router
        assert(is_registered(self, router) == true, 'Router not registered');
        assert(self.blocklisted.read(router) == false, 'Router block listed');
    }
    #[external(v0)]
    fn get_punishment_factor_bips(self: @ContractState) -> u256 {
        self.punishment_factor_bips.read()
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        router_blocklist_event: router_blocklist_event_s,
        binding_balance_event: binding_balance_event_s,
        router_registered_event: router_registered_event_s,
        pending_unregister: pending_unregister_s,
        binding_change_event: binding_change_event_s,
    }
    #[derive(Drop, starknet::Event)]
    struct router_blocklist_event_s {
        router: ContractAddress
    }
    #[derive(Drop, starknet::Event)]
    struct binding_balance_event_s {
        router: ContractAddress,
        token: ContractAddress,
        old_balance: u256,
        balance: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct router_registered_event_s {
        router: ContractAddress,
        old_balance: u256,
        balance: u256,
        // whitelisted_signers: Array::<ContractAddress>,
        registered: bool,
    }
    #[derive(Drop, starknet::Event)]
    struct pending_unregister_s {
        router: ContractAddress,
        registered: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct binding_change_event_s {
        router: ContractAddress,
        signer: ContractAddress,
        is_add: bool,
    }
}
