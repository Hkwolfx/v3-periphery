// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';

import './interfaces/INonfungiblePositionManager.sol';
import './libraries/PositionKey.sol';
import './libraries/FullMath.sol';
import './RouterPositions.sol';

abstract contract NonfungiblePositionManager is INonfungiblePositionManager, ERC721, RouterPositions {
    // details about the uniswap position
    struct Position {
        // the nonce for permits
        uint64 nonce;
        // the immutable pool key of the position
        address token0;
        address token1;
        uint24 fee;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected fees are held by this contract owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @inheritdoc INonfungiblePositionManager
    mapping(uint256 => Position) public override positions;

    uint64 private _nextId = 1;

    constructor() ERC721('Uniswap V3 Positions', 'UNI-V3-POS') {}

    /// @inheritdoc INonfungiblePositionManager
    function firstMint(FirstMintParams calldata params)
        external
        override
        returns (
            uint256 tokenId,
            uint256 amount0,
            uint256 amount1
        )
    {
        (amount0, amount1) = createPoolAndAddLiquidity(
            CreatePoolAndAddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                sqrtPriceX96: params.sqrtPriceX96,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount: params.amount,
                recipient: address(this),
                deadline: params.deadline
            })
        );

        _mint(params.recipient, (tokenId = _nextId++));

        positions[tokenId] = Position({
            nonce: 0,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.amount,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        override
        returns (
            uint256 tokenId,
            uint256 amount0,
            uint256 amount1
        )
    {
        (amount0, amount1) = addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount: params.amount,
                amount0Max: params.amount0Max,
                amount1Max: params.amount1Max,
                recipient: address(this),
                deadline: params.deadline
            })
        );

        _mint(params.recipient, (tokenId = _nextId++));

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(this.factory(), poolKey));

        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);

        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        positions[tokenId] = Position({
            nonce: 0,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.amount,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId));
        _;
    }

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(
        uint256 tokenId,
        uint128 amount,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        Position storage position = positions[tokenId];

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: position.token0, token1: position.token1, fee: position.fee});

        (amount0, amount1) = addLiquidity(
            AddLiquidityParams({
                token0: position.token0,
                token1: position.token1,
                fee: position.fee,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount: amount,
                amount0Max: amount0Max,
                amount1Max: amount1Max,
                recipient: address(this),
                deadline: deadline
            })
        );

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(this.factory(), poolKey));

        // this is now updated to the current transaction
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(
            FullMath.mulDiv(feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, 1 << 128)
        );
        position.tokensOwed1 += uint128(
            FullMath.mulDiv(feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, 1 << 128)
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity += amount;
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(uint256 tokenId, uint256 amount)
        external
        override
        isAuthorizedForToken(tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        revert('TODO');
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(
        uint256 tokenId,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient
    ) external override isAuthorizedForToken(tokenId) returns (uint256 amount0, uint256 amount1) {
        revert('TODO');
    }

    /// @inheritdoc INonfungiblePositionManager
    function exit(uint256 tokenId, address recipient)
        external
        override
        isAuthorizedForToken(tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        revert('TODO');
    }

    /// @inheritdoc INonfungiblePositionManager
    function permit(
        address owner,
        address spender,
        uint256 tokenId,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override checkDeadline(deadline) {
        revert('TODO');
    }
}