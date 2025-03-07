pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/IBeefyVault.sol";
import "./crosschainStablecoin.sol";

contract beefyZapper is Ownable, Pausable, IERC721Receiver {
    using SafeMath for uint256;

    struct MooChain {
        IERC20 asset;
        IBeefyVault mooToken;
        crosschainStablecoin mooTokenVault;
    }

    mapping (bytes32 => MooChain) private _chainWhiteList;

    event AssetZapped(address indexed asset, uint256 indexed amount, uint256 vaultId);
    event AssetUnZapped(address indexed asset, uint256 indexed amount, uint256 vaultId);

    function _beefyZapToVault(uint256 amount, uint256 vaultId, MooChain memory chain) internal whenNotPaused returns (uint256) {
        require(amount > 0, "You need to deposit at least some tokens");

        uint256 allowance = chain.asset.allowance(msg.sender, address(this));
        require(allowance >= amount, "Check the token allowance");
        require(chain.mooTokenVault.exists(vaultId), "VaultId provided doesn't exist");

        chain.asset.transferFrom(msg.sender, address(this), amount);

        chain.asset.approve(address(chain.mooToken), amount);
        uint256 originalMooTokenBal = chain.mooToken.balanceOf(address(this));
        chain.mooToken.deposit(amount);
        uint256 postDepositMooTokenBal = chain.mooToken.balanceOf(address(this));
        uint256 mooTokenBalToZap = postDepositMooTokenBal.sub(originalMooTokenBal);

        chain.mooToken.approve(address(chain.mooTokenVault), mooTokenBalToZap);
        chain.mooTokenVault.depositCollateral(vaultId, mooTokenBalToZap);
        emit AssetZapped(address(chain.asset), amount, vaultId);
        return chain.mooToken.balanceOf(msg.sender);
    }

    function _beefyZapFromVault(uint256 amount, uint256 vaultId, MooChain memory chain) internal whenNotPaused returns (uint256) {
        require(amount > 0, "You need to withdraw at least some tokens");
        require(chain.mooTokenVault.getApproved(vaultId) == address(this), "Need to have approval");
        require(chain.mooTokenVault.ownerOf(vaultId) == msg.sender, "You can only zap out of vaults you own");

        //Transfer vault to this contract
        chain.mooToken.approve(address(chain.mooTokenVault), amount);
        chain.mooTokenVault.safeTransferFrom(msg.sender, address(this), vaultId);

        //Withdraw funds from vault
        uint256 mooTokenBalanceBeforeWithdraw = chain.mooToken.balanceOf(address(this));
        chain.mooTokenVault.withdrawCollateral(vaultId, amount);
        uint256 mooTokenBalanceToUnzap = chain.mooToken.balanceOf(address(this)).sub(mooTokenBalanceBeforeWithdraw);

        //Return vault to user
        chain.mooTokenVault.approve(msg.sender, vaultId);
        chain.mooTokenVault.safeTransferFrom(address(this), msg.sender, vaultId);

        //Withdraw underlying from respective yield bearing asset
        uint256 tokenBalanceBeforeWithdraw = chain.asset.balanceOf(address(this));
        chain.mooToken.withdraw(mooTokenBalanceToUnzap);
        uint256 tokenBalanceToTransfer = chain.asset.balanceOf(address(this)).sub(tokenBalanceBeforeWithdraw);

        //Transfer tokens to user
        chain.asset.approve(address(this), tokenBalanceToTransfer);
        chain.asset.transfer(msg.sender, tokenBalanceToTransfer);

        emit AssetUnZapped(address(chain.asset), amount, vaultId);
        return tokenBalanceToTransfer;
    }

    function _buildMooChain(address _asset, address _mooAsset, address _mooAssetVault) internal returns (MooChain memory){
        MooChain memory chain;
        chain.asset = IERC20(_asset);
        chain.mooToken = IBeefyVault(_mooAsset);
        chain.mooTokenVault = crosschainStablecoin(_mooAssetVault);
        return chain;
    }

    function _hashMooChain(MooChain memory chain) internal returns (bytes32){
        return keccak256(
            abi.encodePacked(address(chain.asset) , address(chain.mooToken), address(chain.mooTokenVault)));
    }

    function isWhiteListed(MooChain memory chain) public returns (bool){
        return address(_chainWhiteList[_hashMooChain(chain)].asset) != address(0x0);
    }

    function addChainToWhiteList(address _asset, address _mooAsset, address _mooAssetVault) public onlyOwner {
        MooChain memory chain = _buildMooChain(_asset, _mooAsset, _mooAssetVault);
        if(!isWhiteListed(chain)){
            _chainWhiteList[_hashMooChain(chain)] = chain;
        } else {
            revert("Chain already in White List");
        }
    }

    function removeChainFromWhiteList(address _asset, address _mooAsset, address _mooAssetVault) public onlyOwner {
        MooChain memory chain = _buildMooChain(_asset, _mooAsset, _mooAssetVault);
        if(isWhiteListed(chain)){
            delete _chainWhiteList[_hashMooChain(chain)];
        } else {
            revert("Chain not in white List");
        }
    }

    function pauseZapping() public onlyOwner {
        pause();
    }

    function resumeZapping() public onlyOwner {
        unpause();
    }

    function beefyZapToVault(uint256 amount, uint256 vaultId, address _asset, address _mooAsset, address _mooAssetVault) public whenNotPaused returns (uint256) {
        MooChain memory chain = _buildMooChain(_asset, _mooAsset, _mooAssetVault);
        require(isWhiteListed(chain), "mooToken chain not in on allowable list");
        return _beefyZapToVault(amount, vaultId, chain);
    }

    function beefyZapFromVault(uint256 amount, uint256 vaultId, address _asset, address _mooAsset, address _mooAssetVault) public whenNotPaused returns (uint256) {
        MooChain memory chain = _buildMooChain(_asset, _mooAsset, _mooAssetVault);
        require(isWhiteListed(chain), "mooToken chain not in on allowable list");
        return _beefyZapFromVault(amount, vaultId, chain);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory data) public returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
