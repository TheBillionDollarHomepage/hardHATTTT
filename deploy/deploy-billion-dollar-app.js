require("@nomiclabs/hardhat-ethers")

//kovan addresses - change if using a different network
const host = "0x22ff293e14F1EC3A09B137e9e06084AFd63adDF9"
const fDAIx = "0xF2d68898557cCb2Cf4C10c3Ef2B034b2a69DAD00"

//your address here...
const owner = "0x67b55a219788EA5D723f25036333485852Fbb945"

//to deploy, run yarn hardhat deploy --network goerli

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments

    const { deployer } = await getNamedAccounts()
    console.log(deployer)

    await deploy("BillionDollarCanvas", {
        from: deployer,
        args: [owner, host, fDAIx, ethers.utils.getAddress("0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F"), 1, 5],
        log: true
    })

    const txn = await createFlowOperation.exec(accounts[0])

    await txn.wait()

    const appFlowRate = await sf.cfaV1.getNetFlow({
        superToken: daix.address,
        account: TradeableCashflow.address,
        providerOrSigner: superSigner
    })
    console.log(appFlowRate)
}
module.exports.tags = ["BillionDollarCanvas"]
