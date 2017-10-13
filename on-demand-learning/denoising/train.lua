-- Code derived from DCGAN and Context Encoder
-- DCGAN: https://github.com/soumith/dcgan.torch
-- Context Encoder: https://github.com/pathak22/context-encoder
-- Ruohan Gao, All rights reserved.
-- Mar. 2017

require 'torch'
require 'nn'
require 'optim'
require 'image'
util = paths.dofile('util.lua')

opt = {
   batchSize = 100,        -- number of samples to produce
   loadSize = 96,          -- resize the loaded image to loadsize maintaining aspect ratio. 0 means don't resize. -1 means scale randomly between [0.5,2] -- see donkey_folder.lua
   fineSize = 64,          -- size of random crops
   nef = 64,               -- #  of encoder filters in first conv layer
   ngf = 64,               -- #  of gen filters in first conv layer
   nc = 3,                 -- #  of channels in input
   nThreads = 4,           -- #  of data loading threads to use
   niter = 25,             -- #  of iter at starting learning rate
   lr = 0.0002,            -- initial learning rate for adam
   beta1 = 0.5,            -- momentum term of adam
   ntrain = math.huge,     -- #  of examples per epoch. math.huge for full dataset
   display = 1,            -- display samples while training. 0 = false
   display_id = 10,        -- display window id.
   display_iter = 50,      -- # number of iterations after which display is updated
   gpu = 1,                -- gpu = 0 is CPU mode. gpu=X is GPU mode on GPU X
   name = 'denoise',       -- name of the experiment you are running
   manualSeed = 0,         -- 0 means random seed
   netG = '',              -- '' means no pre-trained encoder-decoder net provided
   base = 0,               -- initial index base, 0 if training from scratch
   level1 = 20,            -- number of training examples per batch for level 1 sub-task  
   level2 = 20,            -- number of training examples per batch for level 2 sub-task 
   level3 = 20,            -- number of training examples per batch for level 3 sub-task 
   level4 = 20,            -- number of training examples per batch for level 4 sub-task
   level5 = 20,            -- number of training examples per batch for level 5 sub-task 
}

for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
print(opt)
-- set seed
if opt.manualSeed == 0 then
    opt.manualSeed = torch.random(1, 10000)
end
print("Seed: " .. opt.manualSeed)
torch.manualSeed(opt.manualSeed)
torch.setnumthreads(1)
torch.setdefaulttensortype('torch.FloatTensor')

-- create data loader
local DataLoader = paths.dofile('data/data.lua')
local data = DataLoader.new(opt.nThreads, opt)
print("Dataset Size: ", data:size())

---------------------------------------------------------------------------
-- Initialize network variables
---------------------------------------------------------------------------
local function weights_init(m)
   local name = torch.type(m)
   if name:find('Convolution') then
      m.weight:normal(0.0, 0.02)
      m.bias:fill(0)
   elseif name:find('BatchNormalization') then
      if m.weight then m.weight:normal(1.0, 0.02) end
      if m.bias then m.bias:fill(0) end
   end
end

local nc = opt.nc
local ngf = opt.ngf
local nef = opt.nef
local SpatialBatchNormalization = nn.SpatialBatchNormalization
local SpatialConvolution = nn.SpatialConvolution
local SpatialFullConvolution = nn.SpatialFullConvolution

---------------------------------------------------------------------------
-- Generator net
---------------------------------------------------------------------------
-- load or initialize Encoder-Decoder Network
if opt.netG ~= '' then
  netG = util.load(opt.netG, opt.gpu)
else
  print("NO pre-trained generator provided! Initializing new genertor!")
  netE = nn.Sequential()
  -- state size: 1 x 64 x 64
  netE:add(SpatialConvolution(1, nef, 4, 4, 2, 2, 1, 1))
  netE:add(SpatialBatchNormalization(nef)):add(nn.LeakyReLU(0.2, true))
  -- state size: (nef) x 32 x 32
  netE:add(SpatialConvolution(nef, nef * 2, 4, 4, 2, 2, 1, 1))
  netE:add(SpatialBatchNormalization(nef * 2)):add(nn.LeakyReLU(0.2, true))
  -- state size: (nef*2) x 16 x 16
  netE:add(SpatialConvolution(nef * 2, nef * 4, 4, 4, 2, 2, 1, 1))
  netE:add(SpatialBatchNormalization(nef * 4)):add(nn.LeakyReLU(0.2, true))
  -- state size: (nef*4) x 8 x 8
  netE:add(SpatialConvolution(nef * 4, nef * 8, 4, 4, 2, 2, 1, 1))
  netE:add(SpatialBatchNormalization(nef * 8)):add(nn.LeakyReLU(0.2, true))
  -- state size: (nef*8) x 4 x 4

  -- channel-wise fully-connected layer
  local channel_wise = nn.Sequential()
  channel_wise:add(nn.View(nef * 8,16))
  channel_wise:add(nn.SplitTable(1,2))
  c = nn.ParallelTable()
  for i = 1,512 do
     c:add(nn.Linear(16,16))
  end
  channel_wise:add(c)
  channel_wise:add(nn.JoinTable(2))

  netG = nn.Sequential()
  netG:add(netE):add(channel_wise)
  netG:add(nn.View(nef*8,4,4))
  -- Decode to generate image
  -- state size: (ngf*8) x 4 x 4
  netG:add(SpatialFullConvolution(ngf * 8, ngf * 4, 4, 4, 2, 2, 1, 1))
  netG:add(SpatialBatchNormalization(ngf * 4)):add(nn.ReLU(true))
  -- state size: (ngf*4) x 8 x 8
  netG:add(SpatialFullConvolution(ngf * 4, ngf * 2, 4, 4, 2, 2, 1, 1))
  netG:add(SpatialBatchNormalization(ngf * 2)):add(nn.ReLU(true))
  -- state size: (ngf*2) x 16 x 16
  netG:add(SpatialFullConvolution(ngf * 2, ngf, 4, 4, 2, 2, 1, 1))
  netG:add(SpatialBatchNormalization(ngf)):add(nn.ReLU(true))
  -- state size: (ngf) x 32 x 32
  netG:add(SpatialFullConvolution(ngf, 1, 4, 4, 2, 2, 1, 1))
  netG:add(nn.Tanh())
  -- state size: 1 x 64 x 64

  netG:apply(weights_init)
end

--------------------------------------------------------------------------
-- Loss Metrics
-- -----------------------------------------------------------------------
local criterionMSE = nn.MSECriterion()

--------------------------------------------------------------------------
-- Setup Solver
--------------------------------------------------------------------------
optimStateG = {
	learningRate = opt.lr,
	beta1 = opt.beta1,
}

--------------------------------------------------------------------------
-- Initialize data variables
--------------------------------------------------------------------------
local input_image = torch.Tensor(opt.batchSize, 1, opt.fineSize, opt.fineSize)
local input_image_vis = torch.Tensor(opt.batchSize, 1, opt.fineSize, opt.fineSize)
local gray_image = torch.Tensor(opt.batchSize,1,opt.fineSize,opt.fineSize)
local real_frame = torch.Tensor(opt.batchSize, 1, opt.fineSize, opt.fineSize)
local fake_frame = torch.Tensor(opt.batchSize, 1, opt.fineSize, opt.fineSize)
local errG_l2
local epoch_tm = torch.Timer()
local tm = torch.Timer()
local data_tm = torch.Timer()

-- Construct denoise table according to training design of batches
local sigma_table = {20,40,60,80,100}
local batch_sigma = {}
local percentage_table = {opt.level1,opt.level2,opt.level3,opt.level4,opt.level5}
for i = 1,5 do
   for j = 1,percentage_table[i] do
	table.insert(batch_sigma,sigma_table[i])
   end
end

if pcall(require, 'cudnn') and pcall(require, 'cunn') and opt.gpu>0 then
    print('Using CUDNN !')
end
if opt.gpu > 0 then
   require 'cunn'
   cutorch.setDevice(opt.gpu)
   input_image_vis = input_image_vis:cuda(); input_image = input_image:cuda()
   real_frame = real_frame:cuda(); fake_frame = fake_frame:cuda()
   netG = util.cudnn(netG);
   netG:cuda();   
   criterionMSE:cuda();
end
print('NetG:',netG)

if opt.display then disp = require 'display' end
local parametersG, gradParametersG = netG:getParameters()

---------------------------------------------------------------------------
-- Define generator closures
---------------------------------------------------------------------------
-- create closure to evaluate f(X) and df/dX of generator
local fGx = function(x)
   netG:apply(function(m) if torch.type(m):find('Convolution') then m.bias:zero() end end)
   gradParametersG:zero()

   data_tm:reset(); data_tm:resume()
   local real_ctx = data:getBatch()

   -- convert input images to gray-scale images
   real_ctx:add(1):mul(0.5):mul(255)
   real_frame[{{},{},{},{}}] = real_ctx[{{},{1},{},{}}] * 0.2989 + real_ctx[{{},{1},{},{}}] * 0.5870 + real_ctx[{{},{1},{},{}}] * 0.1140
   gray_image:copy(real_frame)
   real_frame:div(255):mul(2):add(-1)

   -- construct corrupted images
   for i = 1, opt.batchSize do
        local noise = torch.Tensor(1, opt.fineSize, opt.fineSize)
	      noise:normal(0,torch.uniform(batch_sigma[i]-20,batch_sigma[i]))
        gray_image[{{i},{},{},{}}]:add(noise:float())
   end
   gray_image = torch.clamp(gray_image, 0, 255)
   gray_image:div(255):mul(2):add(-1)
   input_image:copy(gray_image)
   data_tm:stop()

   -- forward propagation to restore the image
   local fake = netG:forward(input_image)
   fake_frame[{{},{},{},{}}]:copy(fake)
   errG_l2 = criterionMSE:forward(fake_frame, real_frame)
   local df_dg_l2 = criterionMSE:backward(fake_frame, real_frame)
   -- backward propagation to update weights
   netG:backward(input_image, df_dg_l2)
   return errG_l2, gradParametersG
end

---------------------------------------------------------------------------
-- Train Image Denoiser
---------------------------------------------------------------------------
for epoch = 1, opt.niter do
   epoch_tm:reset()
   local counter = 0
   for i = 1, math.min(data:size(), opt.ntrain), opt.batchSize do
      tm:reset()

      -- Update Encoder-Decoder Network
      optim.adam(fGx, parametersG, optimStateG)

      -- Display
      counter = counter + 1
      if counter % opt.display_iter == 0 and opt.display then
         local real_ctx = data:getBatch()
         real_ctx:add(1):mul(0.5):mul(255)
         real_frame[{{},{},{},{}}] = real_ctx[{{},{1},{},{}}] * 0.2989 + real_ctx[{{},{1},{},{}}] * 0.5870 + real_ctx[{{},{1},{},{}}] * 0.1140
         gray_image:copy(real_frame)
         real_frame:div(255):mul(2):add(-1)
         -- construct corrupted images
         for i = 1, opt.batchSize do
              local noise = torch.Tensor(1, opt.fineSize, opt.fineSize)
              noise:normal(0,torch.uniform(batch_sigma[i]-20,batch_sigma[i]))
              gray_image[{{i},{},{},{}}]:add(noise:float())
         end
         gray_image = torch.clamp(gray_image, 0, 255)
         gray_image:div(255):mul(2):add(-1)
         input_image_vis:copy(gray_image) 
         local fake = netG:forward(input_image_vis)
         fake_frame[{{},{},{},{}}]:copy(fake)
         disp.image(real_frame, {win=opt.display_id, title=opt.name .. 'original image'})
         disp.image(gray_image, {win=opt.display_id * 3, title=opt.name .. 'corrupted image'})
         disp.image(fake_frame, {win=opt.display_id * 6, title=opt.name .. 'restored image'})
      end

      -- logging
      if ((i-1) / opt.batchSize) % 1 == 0 then
         print(('Epoch: [%d][%8d / %8d]\t Time: %.3f  DataTime: %.3f  '
                   .. '  Err_G_L2: %.4f'):format(
                 epoch, ((i-1) / opt.batchSize),
                 math.floor(math.min(data:size(), opt.ntrain) / opt.batchSize),
                 tm:time().real, data_tm:time().real, errG_l2 or -1))
      end
   end
   paths.mkdir('checkpoints')
   -- nil them to avoid spiking memory
   parametersG, gradParametersG = nil, nil
   if epoch % 20 == 0 then
      util.save('checkpoints/' .. opt.name .. '_' .. epoch + opt.base .. '_net_G.t7', netG, opt.gpu)
   end
   -- reflatten the params and get them
   parametersG, gradParametersG = netG:getParameters()
   print(('End of epoch %d / %d \t Time Taken: %.3f'):format(
            epoch, opt.niter, epoch_tm:time().real))
end
