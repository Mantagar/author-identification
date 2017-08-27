local RNN={}

local BatchManager=require 'BatchManager'

--Creates model of multiheaded reccurent neural network
function RNN.createModel(input_size,hidden_size,rnn_size,heads)
	local input={}
	local hidden={}
	local output={}
	input[1]=nn.Identity()()
	for i=2,rnn_size+1 do
		input[i]=nn.Identity()()
		local i2h = input[i] - nn.Linear(hidden_size,hidden_size)
		local h2h = i==2 and input[1] - nn.Linear(input_size,hidden_size) or hidden[i-2] - nn.Linear(hidden_size,hidden_size)
		hidden[i-1] = {h2h,i2h} - nn.CAddTable() - nn.Tanh()
		output[heads+i-1] = hidden[i-1]
	end
	for i=1,heads do
		output[i]=hidden[rnn_size] - nn.Linear(hidden_size,input_size)-- - nn.SoftMax()
	end
	--ANNOTATIONS
	for i,each in ipairs(input) do
			each:annotate{name='HIDDEN STATE[t-1]['..(i-1)..']\n', graphAttributes = {style="filled", fillcolor = '#aaaaff'}}
	end
	input[1]:annotate{name='INPUT\n', graphAttributes = {style="filled", fillcolor = '#ffffaa'}}
	for i,each in ipairs(hidden) do
			each:annotate{name='HIDDEN STATE[t]['..i..']\n', graphAttributes = {style="filled", fillcolor = '#ffaaaa'}}
	end
	for i=1,heads do
		output[i]:annotate{name='OUTPUT\nHEAD['..i..']\n', graphAttributes = {style="filled", fillcolor = '#aaffaa'}}
	end

	model=nn.gModule(input,output)
	model.input_size=input_size
	model.hidden_size=hidden_size
	model.rnn_size=rnn_size
	model.heads=heads
	return model
end

--Unfolds model in time for sequences of length seq_size and returns appropriate RNN
function RNN.unfoldModel(model,seq_size)
	--Clone models in time
	rnn={}
	for i=1,seq_size do
		rnn[i]=model:clone()
	end
	--Share weight, bias, gradWeight and gradBias
	local sharedParams,sharedGradParams=rnn[1]:parameters()
	for t=2,seq_size do
		local params,gradParams=rnn[t]:parameters()
		for i=1,#params do
			params[i]:set(sharedParams[i])
			gradParams[i]:set(sharedGradParams[i])
		end
	end
	rnn.seq_size=seq_size
	rnn.hidden_size=model.hidden_size
	rnn.input_size=model.input_size
	rnn.rnn_size=model.rnn_size
	rnn.heads=model.heads

	--Optimization constants
	rnn.ZERO_HEAD_VECTOR=torch.zeros(40,rnn.input_size) --used for gradient inputs of other heads
	rnn.ZERO_HIDDEN_VECTOR=torch.zeros(40,rnn.hidden_size) --used for first hidden state input and last hidden state gradient input
	return rnn
end

--TRAIN UNFOLDED MODEL (one epoch for the chosen author)
function RNN.trainUnfoldedModel(rnn,learning_rate,data,head_no)
	--Batcher preparation
	local batcher=BatchManager.createBatcher(data,40,rnn.input_size)
	--Zero initial gradient
	rnn[1]:zeroGradParameters()
	--If data availible then feed it to the network
	while BatchManager.isNextBatch(batcher) do
		--Initialize the initial hidden state with zero matrices
		local hiddenState={}
		hiddenState[0]={}
		for r=1,rnn.rnn_size do
			hiddenState[0][r]=rnn.ZERO_HIDDEN_VECTOR --passing only reference
		end
		--Initialize minibatches at consecutive timesteps
		local input,label=BatchManager.nextBatch(batcher,rnn.seq_size)
		--Forward through time
		for t=1,rnn.seq_size do
			local inputAndHidden={}
			inputAndHidden[1]=input[t]
			for r=1,rnn.rnn_size do
				inputAndHidden[r+1]=hiddenState[t-1][r]
			end
			--Pass input and previous hidden state at timestep t
			rnn[t]:forward(inputAndHidden)
			--We can get the outputs by calling rnn[t].output
			--Initialize next hidden state
			hiddenState[t]={}
			for r=1,rnn.rnn_size do
				hiddenState[t][r]=rnn[t].output[rnn.heads+r]:clone()
			end
		end
		--Initialize targets (for ClassNLLCriterion and CrossEntropyCriterion instead of providing array we provide the index of one_hot's 1)
		local target={}
		for t=1,rnn.seq_size do
			target[t]=torch.Tensor(40)
			for b=1,40 do
				_,index=label[t][b]:max(1)
				target[t][b]=index
			end
		end
		--Calculate error and gragient loss at every timestep
		local err={}
		local gradLoss={}
		for t=1,rnn.seq_size do
			--Create new criterion for every timestep (CrossEntropy seems to be more robust than ClassNLL)
			local criterion=nn.CrossEntropyCriterion()--nn.ClassNLLCriterion()
			--First output is our prediction
			err[t]=criterion:forward(rnn[t].output[head_no],target[t])
			gradLoss[t]=criterion:backward(rnn[t].output[head_no],target[t])
		end
		--Initialize hidden gradient inputs for last timestep
		local hiddenGradient={}
		hiddenGradient[rnn.seq_size]={}
		for r=1,rnn.rnn_size do
			hiddenGradient[rnn.seq_size][r]=rnn.ZERO_HIDDEN_VECTOR --passing only reference
		end
		--Initialize gradient inputs for heads (all timesteps)
		local headsGradient={}
		for t=1,rnn.seq_size do
			headsGradient[t]={}
			for h=1,rnn.heads do
				headsGradient[t][h]=rnn.ZERO_HEAD_VECTOR --passing only reference
			end
			headsGradient[t][head_no]=gradLoss[t]
		end
		--Backward through time (in reverse to forward)
		for t=rnn.seq_size,1,-1 do
			--Pass input and gradient loss at timestep t
			local gradient={}
			for h=1,rnn.heads do
				gradient[h]=headsGradient[t][h]
			end
			for r=1,rnn.rnn_size do
				gradient[#gradient+1]=hiddenGradient[t][r]
			end
			rnn[t]:backward(input[t],gradient)
			--We can get gradient inputs by calling rnn[t].gradInput
			--Initialize previous hidden gradient
			hiddenGradient[t-1]={}
			for r=1,rnn.rnn_size do
				hiddenGradient[t-1][r]=rnn[t].gradInput[r+1]:clone()
			end
		end
		--We update after every minibatch of size 40
		rnn[1]:updateParameters(learning_rate)
		rnn[1]:zeroGradParameters()
		local avg_err=0
		for every=1,#err do avg_err=avg_err+err[every] end
		avg_err=avg_err/#err
		print("Error for head ",head_no,avg_err)
	end
end

function RNN.makeSnapshot(rnn)
	local path="./snapshots/"..os.time()..".rnn"
	torch.save(path,rnn)
	print("Snapshot saved at "..path)
end

function RNN.loadSnapshot(name)
	local path="./snapshots/"..name
	local rnn=torch.load(path)
	return rnn
end


return RNN
