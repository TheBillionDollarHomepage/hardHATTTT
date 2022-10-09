/* eslint-disable no-undef */

const { Framework } = require("@superfluid-finance/sdk-core")
const { assert } = require("chai")

// TODO BUILD A HARDHAT PLUGIN AND REMOVE WEB3 FROM THIS
const { ethers, web3 } = require("hardhat")

const deployFramework = require("@superfluid-finance/ethereum-contracts/scripts/deploy-framework")
const deployTestToken = require("@superfluid-finance/ethereum-contracts/scripts/deploy-test-token")
const deploySuperToken = require("@superfluid-finance/ethereum-contracts/scripts/deploy-super-token")

// This is only used in the set up, and these are the only functions called in this script.
const daiABI = [
    "function mint(address to,uint256 amount) returns (bool)",
    "function approve(address,uint256) returns (bool)"
]

const provider = web3

let accounts

let sf
let dai
let daix
let superSigner
let BillionDollarCanvas

const errorHandler = err => {
    if (err) throw err
}

before(async function () {
    //get accounts from hardhat
    accounts = await ethers.getSigners()

    //deploy the framework
    await deployFramework(errorHandler, {
        web3,
        from: accounts[0].address
    })

    //deploy a fake erc20 token
    await deployTestToken(errorHandler, [":", "fDAI"], {
        web3,
        from: accounts[0].address
    })

    //deploy a fake erc20 wrapper super token around the fDAI token
    await deploySuperToken(errorHandler, [":", "fDAI"], {
        web3,
        from: accounts[0].address
    })

    //initialize the superfluid framework...put custom and web3 only bc we are using hardhat locally
    sf = await Framework.create({
        networkName: "custom",
        provider,
        dataMode: "WEB3_ONLY",
        resolverAddress: process.env.RESOLVER_ADDRESS, //this is how you get the resolver address
        protocolReleaseVersion: "test"
    })

    superSigner = sf.createSigner({
        signer: accounts[0],
        provider: provider
    })

    //use the framework to get the super toen
    daix = await sf.loadSuperToken("fDAIx")

    //get the contract object for the erc20 token
    let daiAddress = daix.underlyingToken.address
    dai = new ethers.Contract(daiAddress, daiABI, accounts[0])

    let App = await ethers.getContractFactory("BillionDollarCanvas", accounts[0])
    BillionDollarCanvas = await App.deploy(
        ethers.utils.getAddress(accounts[1].address),
        1,
        5
    )

    let RedirectApp = await ethers.getContractFactory("RedirectAll", accounts[0])
    RedirectAll = await RedirectApp.deploy(
        sf.settings.config.hostAddress,
        daix.address,
        ethers.utils.getAddress("0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F"),
        BillionDollarCanvas.address
    )
})

beforeEach(async function () {
    await dai
        .connect(accounts[0])
        .mint(accounts[0].address, ethers.utils.parseEther("1000"))

    await dai
        .connect(accounts[0])
        .approve(daix.address, ethers.utils.parseEther("1000"))

    const daixUpgradeOperation = daix.upgrade({
        amount: ethers.utils.parseEther("1000")
    })

    await daixUpgradeOperation.exec(accounts[0])

    const daiBal = await daix.balanceOf({
        account: accounts[0].address,
        providerOrSigner: accounts[0]
    })
    console.log("daix bal for acct 0: ", daiBal)
})

describe("sending flows", async function () {
    it("Case #1 - Create simple stream", async () => {

        const appInitialBalance = await daix.balanceOf({
            account: RedirectAll.address,
            providerOrSigner: accounts[0]
        })
        var canvasId = '0'
        var uri = 'https://ipfs.io/ipfs/bafybeih6yswzweeyau5k7nd7jy4fgf52nkj4ukjwostmsrpwxqcoqk2aty/metadata.json'
        var price = '5'
        var ctx = web3.eth.abi.encodeParameters(['uint256' ,'string', 'uint256'], [canvasId, uri, price])

        // approve for transering dai
        await dai.approve(RedirectAll.address, price);

        const createFlowOperation = sf.cfaV1.createFlow({
            receiver: RedirectAll.address,
            superToken: daix.address,
            flowRate: "100000000",
            overrides: { gasLimit: 3000000 },
            userData: ctx
        })

        const txn = await createFlowOperation.exec(accounts[0])

        await txn.wait()

        const appFlowRate = await sf.cfaV1.getNetFlow({
            superToken: daix.address,
            account: RedirectAll.address,
            providerOrSigner: superSigner
        })

        const ownerFlowRate = await sf.cfaV1.getNetFlow({
            superToken: daix.address,
            account: ethers.utils.getAddress("0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F"),
            providerOrSigner: superSigner
        })

        const appFinalBalance = await daix.balanceOf({
            account: RedirectAll.address,
            providerOrSigner: superSigner
        })

        assert.equal(
            ownerFlowRate,
            "100000000",
            "owner not receiving 100% of flowRate"
        )

        assert.equal(appFlowRate, 0, "App flowRate not zero")

        assert.equal(
            appInitialBalance.toString(),
            appFinalBalance.toString(),
            "balances aren't equal"
        )

        console.log(await BillionDollarCanvas.priceOf(0))
    })
})