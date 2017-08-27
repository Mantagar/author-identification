torch.setnumthreads(1) --after reinstalling torch script slowed 10 times, it brings back performance to about 2 times the time before upgrade
local TP=require 'data/text_processor.lua'

function getAuthorsData(amount)
	local i=1
	local authors={}
	local pfile = io.popen('ls data/binary_authors | head -n '..amount)
	for filename in pfile:lines() do
		print("Author "..i.."...")
		authors[i]=torch.load('./data/binary_authors/'..filename)
		i = i + 1
	end
	pfile:close()
	return authors
end
print("Loading authors' data...")
local authors=getAuthorsData(20)
print("All loaded")

require 'nn'
require 'nngraph'

local RNN=require 'RNN'

local isize=#authors[1][1].alphabet--get size of the first document's alphabet 
local hsize=199
local rnn_size=3
local seq_size=20
local heads=#authors
local model=RNN.createModel(isize,hsize,rnn_size,heads)
graph.dot(model.fg,"multihead-model","mulithead-model")

local rnn=RNN.unfoldModel(model,seq_size)

local learning_factor=0.002
local factor_decay=0.97
local epochs=5
for i=1,epochs do
	for author_no=1,#authors do
		for doc_no=1,#authors[author_no] do
			print("Epoch "..i.."/"..epochs,"Author "..author_no.."/"..#authors,"Document "..doc_no.."/"..#authors[author_no])
			RNN.trainUnfoldedModel(rnn,learning_factor,authors[author_no][doc_no],author_no)
		end
	end
	if i%5==0 then
		local mem=collectgarbage("count")
		collectgarbage()
		print("Garbage collector run.")
		print("Memory before = ",mem)
		print("Memory after = ",collectgarbage("count"))
	end
	learning_factor=learning_factor*factor_decay
end
print("Learning finished")
print("Saving snapshot...")
RNN.makeSnapshot(rnn)

