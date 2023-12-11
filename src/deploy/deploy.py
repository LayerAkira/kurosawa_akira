import asyncio
from pathlib import Path

from starknet_py.hash.casm_class_hash import compute_casm_class_hash
from starknet_py.net.account.account import Account
from starknet_py.net.gateway_client import GatewayClient
from starknet_py.net.models.chains import StarknetChainId
from starknet_py.net.schemas.gateway import CasmClassSchema
from starknet_py.net.signer.stark_curve_signer import KeyPair
from starknet_py.net.udc_deployer.deployer import Deployer

testnet = "testnet"
MAX_FEE = 100000000000


async def deploy(contract_name, raw_calldata, net_type):
    try:
        print(contract_name)
        client = None
        if net_type == "testnet":
            client = GatewayClient(net=testnet)
        if net_type == "localnet":
            client = GatewayClient("http://127.0.0.1:5050")
        deployer_account = Account(
                client=client,
                address="0x6fd7354452299b66076d0a7e88a1635cb08506f738434e95ef5cf4ee5af2e0c",
                key_pair=KeyPair(private_key=0x5a04c74b6efdaabfc41975de2498a89ae5418ef5772ff6404b5be1741d58577,
                                 public_key=0x5ae1a840919c6268f6925c6753e42796c3afe44221126ef999124906990ce15),
                chain=StarknetChainId.TESTNET,
        )

        casm_class = CasmClassSchema().loads(Path(f"../../target/dev/kurosawa_akira_{contract_name}.compiled_contract_class.json").read_text())
        casm_class_hash = compute_casm_class_hash(casm_class)
        declare_transaction = await deployer_account.sign_declare_v2_transaction(
                compiled_contract=Path(f"../../target/dev/kurosawa_akira_{contract_name}.contract_class.json").read_text(),
                compiled_class_hash=casm_class_hash, max_fee=int(1e14))
        print(f"declare_transaction: {hex(declare_transaction.calculate_hash(chain_id=StarknetChainId.TESTNET))}")
        resp = await deployer_account.client.declare(transaction=declare_transaction)
        await deployer_account.client.wait_for_tx(resp.transaction_hash)
        class_hash = resp.class_hash
        print(f"Declared class hash: {class_hash}, {hex(class_hash)}")
        udc_deployer = Deployer()
        contract_deployment = udc_deployer.create_contract_deployment_raw(class_hash=class_hash,
                                                                          raw_calldata=raw_calldata)
        deploy_invoke_transaction = await deployer_account.sign_invoke_transaction(calls=contract_deployment.call, max_fee=int(1e14))
        print(f"deploy_invoke_transaction: {hex(deploy_invoke_transaction.calculate_hash(chain_id=StarknetChainId.TESTNET))}")
        resp = await deployer_account.client.send_transaction(deploy_invoke_transaction)
        await deployer_account.client.wait_for_tx(resp.transaction_hash)
        address = contract_deployment.address
        print(f"Contract address: {hex(address)}")
        file_path = f"./{contract_name}"
        with open(file_path, 'w') as file:
            file.write(hex(address))
        return int(hex(address), 16)
    except:
        file_path = f"{contract_name}"
        with open(file_path, 'r') as file:
            s = file.read()
            print(s)
            return int(s, 16)


async def main():
    # contract_name = "ExchangeBalance"
    # # 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36
    # raw_calldata = [0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7,
    #                 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36]
    # net_type = "testnet"
    # ExchangeBalance = await deploy(contract_name, raw_calldata, net_type)

    # contract_name = "SlowMode"
    # # 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36
    # raw_calldata = [0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36,
    #                 0x05,
    #                 0x03e8]
    # net_type = "testnet"
    # SlowMode = await deploy(contract_name, raw_calldata, net_type)

    # contract_name = "DepositContract"
    # # 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36
    # raw_calldata = [SlowMode, ExchangeBalance]
    # net_type = "testnet"
    # DepositContract = await deploy(contract_name, raw_calldata, net_type)

    # contract_name = "WithdrawContract"
    # # 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36
    # raw_calldata = [SlowMode, ExchangeBalance]
    # net_type = "testnet"
    # WithdrawContract = await deploy(contract_name, raw_calldata, net_type)

    # contract_name = "AKIRA_exchange"
    # # 0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36
    # raw_calldata = [0x166db0a0758b72c6c89bf5ac6942aeaa0ee281eaae34f06bee74ce29ae4cd36,
    #                 0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7,
    #                 0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7,
    #                 0x012D537DC323c439dC65C976FAD242D5610d27cFb5F31689a0a319b8BE7f3d56,
    #                 0x005A643907b9a4Bc6a55E9069C4fD5fd1f5C79a22470690f75556C4736e34426,
    #                 WithdrawContract, DepositContract]
    net_type = "testnet"
    contract_name = "LayerAkira"
    raw_calldata = []
    WithdrawContract = await deploy(contract_name, raw_calldata, net_type)


async def run():
    task = asyncio.create_task(main())
    await task
    ex1 = task.exception()
    if ex1:
        raise ex1


asyncio.run(run())
