const { ethers } = require("hardhat");
const path = require("path");
const chai  = require("chai");
const {assert}  = require("chai");
chai.use(require('chai-as-promised'))


describe("My Dapp", function () {
    describe("YourContract", function () {
        let camTokenFactory, camZapperFactory, erc20Factory, erc20StablecoinVaultFactory, priceSource, vaultId;

        it("Should setup required contract factories", async () => {
            camTokenFactory = await ethers.getContractFactory(path.join("contracts","camToken.sol:camToken"))
            camZapperFactory  = await ethers.getContractFactory(path.join("contracts","camZapper.sol:camZapper"))
            erc20Factory = await ethers.getContractFactory(path.join("contracts","simpleErc20.sol:simpleErc20"))
            erc20StablecoinVaultFactory = await ethers.getContractFactory("erc20Stablecoin");
            priceSource = await ethers.getContractAt("PriceSource", "0x0fda41a1d4555b85021312b765c6d519b9c66f93");
        });

        let token, amToken, camToken, mimatic, vault, zapper,
         camWETHInfo = {
            amToken:"0x28424507fefb6f7f8e9d3860f56504e4e5f5f390",
            camToken: "0x0470CD31C8FcC42671465880BA81D631F0B76C1D",
            decimals: "18",
            name: "Compounding Aave Market WETH",
            symbol: "camWETH",
            underlying: "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619",
        },
        wethAccountAddress = "0x6cc12f719081bc13d50029b6E18E7464B14d467c";

        it("should setup the camToken chain, zapper, MAI, and vault", async () =>{
            mimatic = await erc20Factory.deploy(
              "10000000000000000000000000",
              "miMatic",
              "miMatic",
              18
            );
            token = await erc20Factory.attach(camWETHInfo.underlying);
            amToken = await erc20Factory.attach(camWETHInfo.amToken);
            camToken  = await camTokenFactory.attach(camWETHInfo.camToken);
            zapper = await camZapperFactory.deploy();

            //Vault based on https://polygonscan.com/address/0x11A33631a5B5349AF3F165d2B7901A4d67e561ad
            vault = await erc20StablecoinVaultFactory.deploy(
              priceSource.address,
              135,
              "camToken MAI Vault ",
              "camTKNVT",
              mimatic.address,
              camToken.address,
              "0x4920184F60221a75Abf39BB0b4D06ac25D9b2bb2", //VaultMetaRegistry
              "" //BaseUri, which is empty in deployed code
            )

            await zapper.addChainToWhiteList(token.address, amToken.address, camToken.address, vault.address)

            await vault.createVault();
        })

        let wethAccountSigner, deployerAccount;
        it('Should impersonate the weth holder account and fetch deployer account', async () => {
            await ethers.provider.send('hardhat_impersonateAccount', [wethAccountAddress])
            wethAccountSigner = await ethers.getSigner(wethAccountAddress);
            deployerAccount = (await ethers.getSigners())[0];
        });

        it("Should send WETH to deployer account", async () => {
            let wethHolderTokenContract = token.connect(wethAccountSigner);
            let wethHolderBalance = await wethHolderTokenContract.balanceOf(wethAccountSigner.address);
            await wethHolderTokenContract.transfer(deployerAccount.address, wethHolderBalance);
        })

        let preZapTokenBal;

        it("Should approve the zapper contract to zap weth", async () => {
            preZapTokenBal = await token.balanceOf(deployerAccount.address);
            await token.approve(zapper.address, preZapTokenBal);
        })

        it("Should Zap the funds into the Vault", async function () {
            const zapAmount = preZapTokenBal.div(2);
            await vault.createVault();
            vaultId = await vault.tokenOfOwnerByIndex(deployerAccount.address, 1);
            await zapper.camZapToVault(zapAmount, vaultId, token.address, amToken.address, camToken.address, vault.address);

            let postZapTokenBal = ethers.utils.formatUnits(await token.balanceOf(deployerAccount.address))
            let vaultColat = parseFloat(ethers.utils.formatUnits(await vault.vaultCollateral(vaultId)));

            assert.approximately(vaultColat,
              parseFloat(ethers.utils.formatUnits(zapAmount)) * 0.995,
              0.1,
              "vault collateral should be about 99.5% of the deposited balance");
            assert.equal(parseFloat(postZapTokenBal), ethers.utils.formatUnits(zapAmount), "sender token balance should be 0 after zapping")
        });

        it("Should UnZap the funds out of the Vault", async function () {
            const preZapOutTokenBal = await token.balanceOf(deployerAccount.address);
            vaultId = await vault.tokenOfOwnerByIndex(deployerAccount.address,1);
            let halfCollat = (await vault.vaultCollateral(vaultId)).div(2);
            await vault.approve(zapper.address, vaultId)
            console.log({halfCollat , vaultId})
            await zapper.camZapFromVault(halfCollat, vaultId, token.address, amToken.address, camToken.address, vault.address);


            assert.approximately(parseFloat(ethers.utils.formatUnits(await token.balanceOf(deployerAccount.address))),
              parseFloat(ethers.utils.formatUnits(halfCollat.add(preZapOutTokenBal))) * 1.005,
              0.01,
              "token balance should be about 100.5% of the unzapped collateral balance");
            assert.equal(parseFloat(ethers.utils.formatUnits(await vault.vaultCollateral(vaultId))), parseFloat(ethers.utils.formatUnits(halfCollat)), "should leave some in the vault after zapping")
        });

    }).timeout(1000000);
});
