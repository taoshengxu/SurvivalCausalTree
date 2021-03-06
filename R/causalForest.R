init.causalForest <- function(formula, data, treatment, weights=F, cost=F, num.trees) { 
  num.obs <- nrow(data)
  trees <- vector("list", num.trees)
  inbag <- matrix(0, num.obs, num.trees) 
  causalForestobj <- list(trees = trees, formula=formula, data=data, treatment=treatment, weights=weights, cost=cost, ntree = num.trees, inbag = inbag) 
  class(causalForestobj) <- "causalForest" 
  return(causalForestobj)
} 

predict.causalForest <- function(forest, newdata, predict.all = FALSE, type="vector") {
  if (!inherits(forest, "causalForest")) stop("Not a legitimate \"causalForest\" object")  

  individual <- sapply(forest$trees, function(tree.fit) {
    predict(tree.fit, newdata=newdata, type="vector")
  })
  
  aggregate <- rowMeans(individual)
  if (predict.all) {
    list(aggregate = aggregate, individual = individual)
  } else {
    aggregate
  }
}

causalForest <- function(formula, data, treatment,  
                         na.action = na.causalTree, 
                         split.Rule="CT", split.Honest=T, split.Bucket=F, bucketNum = 5,
                         bucketMax = 100, cv.option="CT", cv.Honest=T, minsize = 2L, 
                         propensity, control, split.alpha = 0.5, cv.alpha = 0.5,
                         
                         sample.size.total = floor(nrow(data) / 10), sample.size.train.frac = .5,
                         mtry = ceiling(ncol(data)/3), nodesize = 1, num.trees=nrow(data),
                         cost=F, weights=F) {
  
  # do not implement subset option of causalTree, that is inherited from rpart but have not implemented it here yet

  num.obs <-nrow(data)
  causalForest.hon <- init.causalForest(formula=formula, data=data, treatment=treatment, weights=weights, cost=cost, num.trees=num.trees)
  sample.size <- min(sample.size.total, num.obs)
  train.size <- round(sample.size.train.frac*sample.size)
  est.size <- sample.size - train.size
  

  treatmentdf <- data.frame(treatment)
  
  print("Building trees ...")
  
  for (tree.index in 1:num.trees) {
    
    print(paste("Tree", as.character(tree.index)))
    
    full.idx <- sample.int(num.obs, sample.size, replace = FALSE)
    train.idx <- full.idx[1:train.size]
    reestimation.idx <- full.idx[(train.size+1):sample.size]
    
    dataTree <- data.frame(data[train.idx,])
    dataEstim <- data.frame(data[reestimation.idx,])

    tree.honest <- honest.causalTree(formula=formula, data = dataTree, 
                                     treatment = treatmentdf[train.idx,], 
                                     est_data=dataEstim, est_treatment=treatmentdf[reestimation.idx,],
                                     split.Rule="CT", split.Honest=T, split.Bucket=split.Bucket, 
                                     bucketNum = bucketNum, 
                                     bucketMax = bucketMax, cv.option="CT", cv.Honest=T, 
                                     minsize = nodesize, 
                                     split.alpha = 0.5, cv.alpha = 0.5, xval=0, 
                                     HonestSampleSize=est.size, cp=0)


    causalForest.hon$trees[[tree.index]] <- tree.honest
    causalForest.hon$inbag[full.idx, tree.index] <- 1
  }
  
  return(causalForest.hon)
}


propensityForest <- function(formula, data, treatment,  
                         na.action = na.causalTree, 
                         split.Rule="CT", split.Honest=T, split.Bucket=F, bucketNum = 5,
                         bucketMax = 100, cv.option="CT", cv.Honest=T, minsize = 2L, 
                         propensity=mean(treatment), control, split.alpha = 0.5, cv.alpha = 0.5,  
                         
                         sample.size.total = floor(nrow(data) / 10), sample.size.train.frac = 1,
                         mtry = ceiling(ncol(data)/3), nodesize = 1, num.trees=nrow(data)) {
  
  # do not implement subset option of causalTree, inherited from rpart
  # do not implement weights and costs yet
  
  if(sample.size.train.frac != 1) {
    print("warning: for propensity Forest, sample.size.train.frac should be 1; resetting to 1")
    sample.size.train.frac <- 1
  }
  
  num.obs <-nrow(data)
  

  causalForest.hon <- init.causalForest(formula=formula, data=data, treatment=treatment, num.trees=num.trees, weights=F, cost=F)
  sample.size <- min(sample.size.total, num.obs)
  train.size <- round(sample.size.train.frac*sample.size)
  
  treatmentdf <- data.frame(treatment)
  outcomename = as.character(formula[2])
  
  print("Building trees ...")
  
  for (tree.index in 1:num.trees) {
    
    print(paste("Tree", as.character(tree.index)))
    
    full.idx <- sample.int(num.obs, sample.size, replace = FALSE)
    train.idx <- full.idx[1:train.size]
    
    # rename variables as a way to trick rpart into building the tree with all the object attributes considering the outcome variable as named
    # by the input formula, even though the tree itself is trained on w.  Note that we aren't saving out this propensity tree anyway, but if
    # we decided later to try to save out the propensity trees and do something directly with the propensity scores, we would need to do something
    # more tedious like estimate the propensity tree with the original names, and then edit the attributes to replace the treatment variable name
    # with the outcome variable name for the estimate part
    dataTree <- data.frame(data[train.idx,])
    dataTree$treattreat <- treatmentdf[train.idx,]
    names(dataTree)[names(dataTree)==outcomename] <- "temptemp"

    names(dataTree)[names(dataTree)=="treattreat"] <- outcomename
    
    
    #one options: estimate the propensity tree with anova so that it will be type "anova" when we re-estimate
    #here: replace elements of the rpart object to make it look like anova tree, so that we'll be able to properly predict with it later, etc.
    tree.propensity <- rpart(formula=formula, data=dataTree, method="class", 
                             control=rpart.control(cp=0, minbucket=nodesize))
    
    # make it look like a method="anova" tree 
    tree.propensity$method <- "anova"
    tree.propensity$frame$yval2 <- NULL
    tree.propensity$functions$print <- NULL
    
    # switch the names back in the data frame so that when we estimate treatment effects, will have the right outcome variables
    names(dataTree)[names(dataTree)==outcomename] <- "treattreat"
    names(dataTree)[names(dataTree)=="temptemp"] <- outcomename
    tree.treatment <- estimate.causalTree(object=tree.propensity,data=dataTree, treatment=dataTree$treattreat)
    
    causalForest.hon$trees[[tree.index]] <- tree.treatment
    causalForest.hon$inbag[full.idx, tree.index] <- 1
  }
  
  return(causalForest.hon)
}