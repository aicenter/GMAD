using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
using Flux
using GenerativeModels

s = ArgParseSettings()
@add_arg_table! s begin
	"max_seed"
		default = 1
		arg_type = Int
		help = "max_seed"
	"category"
		default = "wood"
		arg_type = String
		help = "category"
	"contamination"
		arg_type = Float64
		help = "contamination rate of training data"
		default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack category, max_seed, contamination = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################
modelname = "aae"

# sample parameters, should return a Dict of model kwargs 
"""
	sample_params()

Should return a named tuple that contains a sample of model parameters.
"""
function sample_params()
	# first sample the number of layers
	nlayers = rand(2:4)
	kernelsizes = reverse((3,5,7,9)[1:nlayers])
	channels = reverse((16,32,64,128)[1:nlayers])
	scalings = reverse((1,2,2,2)[1:nlayers])
	var = "conv"
	
	par_vec = (2 .^(3:8), 10f0 .^(-4:-3), 2 .^ (3:5), ["relu", "swish", "tanh"], 1:Int(1e8),
						10f0 .^(-1:0), 1:3)
	argnames = (:zdim, :lr, :batchsize, :activation, :init_seed, :lambda, :dnlayers)
	parameters = (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
	return merge(parameters, (nlayers=nlayers, kernelsizes=kernelsizes,
		channels=channels, scalings=scalings, var=var))
end
sample_reconstruction_batched(m,x,L,batchsize) = 
	vcat(map(y->cpu(Base.invokelatest(GenerativeAD.Models.reconstruction_score, m, gpu(y), L)), 
		Flux.Data.DataLoader(x, batchsize=batchsize))...)
"""
	fit(data, parameters)

This is the most important function - returns `training_info` and a tuple or a vector of tuples `(score_fun, final_parameters)`.
`training_info` contains additional information on the training process that should be saved, the same for all anomaly score functions.
Each element of the return vector contains a specific anomaly score function - there can be multiple for each trained model.
Final parameters is a named tuple of names and parameter values that are used for creation of the savefile name.
"""
function fit(data, parameters)
	# first construct the VAMP pseudoinput array
	X = data[1][1]
	pseudoinput_mean = mean(X, dims=ndims(X))

	# construct model - constructor should only accept kwargs
	idim = size(X)[1:3]

	# construct model - constructor should only accept kwargs
	model = GenerativeAD.Models.conv_aae_constructor(;idim=idim, prior="vamp", 
		pseudoinput_mean=pseudoinput_mean, parameters...) |> gpu

	# fit train data
	try
		global info, fit_t, _, _, _ = @timed fit!(model, data; max_iters=20000,
			max_train_time=23*3600/max_seed/4, patience=20, check_interval=50,
			usegpu=true, parameters...)
	catch e
		# return an empty array if fit fails so nothing is computed
		@info "Failed training due to \n$e"
		return (fit_t = NaN, history=nothing, npars=nothing, model=nothing), [] 
	end
	model = info.model
	
	# produce encodings
	if model != nothing
		encodings = map(x->cpu(GenerativeAD.Models.encode_mean_gpu(model, x, 128)), (data[1][1], data[2][1], data[3][1]))
	else
		encodings = (nothing, nothing, nothing)
	end

	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = fit_t,
		history = info.history,
		npars = info.npars,
		model = model |> cpu,
		tr_encodings = encodings[1],
		val_encodings = encodings[2],
		tst_encodings = encodings[3]
		)

	# now return the different scoring functions
	L = 100
	batchsize = 32
	training_info, [
		(x -> sample_reconstruction_batched(model, x, L, batchsize), 
			merge(parameters, (score = "reconstruction-sampled",L=L))),
		]
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# only execute this if run directly - so it can be included in other files
if abspath(PROGRAM_FILE) == @__FILE__
	# set a maximum for parameter sampling retries
	try_counter = 0
	max_tries = 10*max_seed
	cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"
	while try_counter < max_tries
		parameters = sample_params()

		for seed in 1:max_seed
			savepath = datadir("experiments/images_mvtec$cont_string/$(modelname)/$(category)/ac=1/seed=$(seed)")
			mkpath(savepath)

			# get data
			data = GenerativeAD.load_data("MVTec-AD", seed=seed, category=category, 
				contamination=contamination, img_size=128)
			
			# edit parameters
			edited_parameters = GenerativeAD.edit_params(data, parameters)

			@info "Trying to fit $modelname on $category with parameters $(edited_parameters)..."
			@info "Train/validation/test splits: $(size(data[1][1], 4)) | $(size(data[2][1], 4)) | $(size(data[3][1], 4))"
			@info "Number of features: $(size(data[1][1])[1:3])"

			# check if a combination of parameters and seed alread exists
			if GenerativeAD.check_params(savepath, edited_parameters)
				# fit
				training_info, results = fit(data, edited_parameters)

				# save the model separately			
				if training_info.model != nothing
					tagsave(joinpath(savepath, savename("model", edited_parameters, "bson", digits=5)), 
						Dict("model"=>training_info.model,
							 "tr_encodings"=>training_info.tr_encodings,
							 "val_encodings"=>training_info.val_encodings,
							 "tst_encodings"=>training_info.tst_encodings,
							 "fit_t"=>training_info.fit_t,
							 "history"=>training_info.history,
							 "parameters"=>edited_parameters
							 ), 
						safe = true)
					training_info = merge(training_info, 
						(model=nothing,tr_encodings=nothing,val_encodings=nothing,tst_encodings=nothing))
				end

				# here define what additional info should be saved together with parameters, scores, labels and predict times
				save_entries = merge(training_info, (modelname = modelname, seed = seed, 
					category = category,
					contamination=contamination))

				# now loop over all anomaly score funs
				for result in results
					GenerativeAD.experiment(result..., data, savepath; save_entries...)
				end
				global try_counter = max_tries + 1
			else
				@info "Model already present, trying new hyperparameters..."
				global try_counter += 1
			end
		end
	end
	(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
end
